import XCTest
import Foundation
import MediaIO
import AudioCore
import CDoPTransport

final class DSDTests: XCTestCase {
    private func integer(_ x: UInt64, _ n:Int, little:Bool) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded:x >> (8*(little ? $0 : n-$0-1))) })
    }
    private func dsf(left:[UInt8],right:[UInt8],rate:UInt64=2_822_400,bits:UInt64=8,samples:UInt64?=nil) -> Data {
        let samples=samples ?? UInt64(left.count*8)
        let blocks=(left.count+4095)/4096
        var d=Data("DSD ".utf8)
        for v:UInt64 in [28,UInt64(92+blocks*8192),0] { d+=integer(v,8,little:true) }
        d+=Data("fmt ".utf8); d+=integer(52,8,little:true)
        for v:UInt64 in [1,0,2,2,rate,bits] { d+=integer(v,4,little:true) }
        d+=integer(samples,8,little:true); d+=integer(4096,4,little:true); d+=Data(repeating:0,count:4)
        d+=Data("data".utf8); d+=integer(UInt64(blocks*8192+12),8,little:true)
        for b in 0..<blocks { for channel in [left,right] {
            let n=min(4096,channel.count-b*4096)
            d+=Data(channel[b*4096..<b*4096+n]); d+=Data(repeating:0,count:4096-n)
        } }
        return d
    }
    private func chunk(_ id:String,_ data:Data) -> Data {
        Data(id.utf8)+integer(UInt64(data.count),8,little:false)+data+(data.count%2==1 ? Data([0]) : Data())
    }
    private func dff(_ bytes:Data, compression:String="DSD ") -> Data {
        let prop=Data("SND ".utf8)+chunk("FS  ",integer(2_822_400,4,little:false))+chunk("CHNL",Data([0,2])+Data("SLFTSRGT".utf8))+chunk("CMPR",Data(compression.utf8))
        let content=Data("DSD ".utf8)+chunk("PROP",prop)+chunk("DSD ",bytes)
        return Data("FRM8".utf8)+integer(UInt64(content.count),8,little:false)+content
    }
    private func withReader(_ bytes:Data, _ body:(DSDStreamReader) throws -> Void) throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".dsf")
        try bytes.write(to:url); defer { try? FileManager.default.removeItem(at:url) }
        try body(DSDStreamReader(url:url))
    }
    func testSonyLSBAndMSBAndDFFProduceIdenticalChronologicalBits() throws {
        let expected=Data([0x80,0x40,0xC0,0x20,0x96,0x69,0x12,0x34])
        try withReader(dsf(left:[1,2,0x69,0x96],right:[3,4,0x48,0x2c],bits:1)) { r in
            XCTAssertEqual(try r.readFrames(8),expected); XCTAssertEqual(try r.readFrames(8),Data())
        }
        try withReader(dsf(left:[0x80,0x40,0x96,0x69],right:[0xC0,0x20,0x12,0x34])) { r in XCTAssertEqual(try r.readFrames(1)+r.readFrames(1),expected) }
        try withReader(dff(Data([0x80,0xC0,0x40,0x20,0x96,0x12,0x69,0x34]))) { r in XCTAssertEqual(try r.readFrames(8),expected) }
    }
    func testBlockBoundarySeekAndPartialSamplePadding() throws {
        let left=(0..<4100).map { UInt8(truncatingIfNeeded:$0) }, right=(0..<4100).map { UInt8(truncatingIfNeeded:255-$0) }
        try withReader(dsf(left:left,right:right,rate:5_644_800)) { r in
            XCTAssertEqual(r.info.carrierRate,352800)
            _=try r.readFrames(2047)
            XCTAssertEqual(try r.readFrames(2),Data([254,255,1,0,0,1,255,254]))
            r.seek(to:Double(2048)/r.info.carrierRate)
            XCTAssertEqual(try r.readFrames(1),Data([0,1,255,254]))
            r.seek(to:r.info.duration); XCTAssertTrue(try r.readFrames(1).isEmpty)
        }
        try withReader(dsf(left:[0xFF,0xFF],right:[0,0],samples:9)) { r in
            // One valid bit of the second byte, then DSD silence; no zero block padding leaks.
            XCTAssertEqual(try r.readFrames(8),Data([0xFF,0xE9,0,0x69]))
        }
        try withReader(dff(Data([0x12,0x34]))) { r in XCTAssertEqual(try r.readFrames(1),Data([0x12,0x69,0x34,0x69])) }
    }
    func testRejectsTruncatedCorruptUnsupportedRateAndDST() throws {
        XCTAssertThrowsError(try withReader(dsf(left:[1,2],right:[3,4]).dropLast()) { _ in })
        XCTAssertThrowsError(try withReader(dsf(left:[1,2],right:[3,4],rate:11_289_600)) { _ in })
        XCTAssertThrowsError(try withReader(dff(Data([1,2,3,4]),compression:"DST ")) { _ in })
        var corrupt=dsf(left:[1,2],right:[3,4]); corrupt[52]=6
        XCTAssertThrowsError(try withReader(corrupt) { _ in })
        corrupt=dsf(left:[1,2],right:[3,4]); corrupt[88]=0xFF
        XCTAssertThrowsError(try withReader(corrupt) { _ in })
    }
    func testRealtimeRingLayoutPauseUnderrunPhaseWrapAndEOF() throws {
        let s=try XCTUnwrap(negi_dop_create(2)); defer { negi_dop_destroy(s) }
        func write(_ a:[UInt8]) { a.withUnsafeBufferPointer { XCTAssertEqual(negi_dop_write(s,$0.baseAddress,UInt32(a.count/4)),UInt32(a.count/4)) } }
        func render(_ n:Int)->[UInt8] { var a=[UInt8](repeating:0,count:n*6); a.withUnsafeMutableBufferPointer { negi_dop_render(s,$0.baseAddress,UInt32(n)) }; return a }
        write([0x12,0x34,0x56,0x78,0x9A,0xBC,0xDE,0xF0])
        XCTAssertEqual(render(1),[0x69,0x69,5,0x69,0x69,5]); XCTAssertEqual(negi_dop_played(s),0)
        negi_dop_pause(s,0)
        XCTAssertEqual(render(1),[0x34,0x12,0xFA,0x78,0x56,0xFA])
        write([1,2,3,4]) // wrap, retaining the original second frame
        XCTAssertEqual(render(2),[0xBC,0x9A,5,0xF0,0xDE,5,2,1,0xFA,4,3,0xFA])
        XCTAssertEqual(render(1),[0x69,0x69,5,0x69,0x69,5]); XCTAssertEqual(negi_dop_underruns(s),1)
        write([0x80,0x40,0x20,0x10]); negi_dop_eof(s)
        XCTAssertEqual(render(1),[0x40,0x80,0xFA,0x10,0x20,0xFA]); XCTAssertEqual(negi_dop_drained(s),1)
        _=render(3); XCTAssertEqual(negi_dop_underruns(s),1); XCTAssertEqual(negi_dop_played(s),4)
        negi_dop_reset(s); write([1,2,3,4]); XCTAssertEqual(render(1),[2,1,5,4,3,5])
    }
}
