import XCTest
import MediaIO

final class MetadataTests: XCTestCase {
    func testFLACMultiValuesAndCorruptLengths() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".flac")
        defer { try? FileManager.default.removeItem(at: url) }
        func le(_ n: Int) -> Data { Data((0..<4).map { UInt8((n >> ($0*8)) & 255) }) }
        let comments = ["TITLE=原文 é", "ARTIST=AC/DC", "ARTIST=A & B", "ALBUMARTIST=Various", "ALBUM=专辑", "TRACKNUMBER=03/12", "DISCNUMBER=2", "CUSTOM=保留字段"]
        var block = le(0)+le(comments.count)
        for comment in comments { let data = Data(comment.utf8); block += le(data.count)+data }
        let header = Data([0x84,UInt8((block.count >> 16) & 255),UInt8((block.count >> 8) & 255),UInt8(block.count & 255)])
        let content = Data("fLaC".utf8)+header+block
        try content.write(to: url)
        let tags = try FLACMetadata.read(url)
        XCTAssertEqual(tags["artist"],["AC/DC","A & B"])
        XCTAssertEqual(tags["albumArtist"],["Various"])
        XCTAssertEqual(tags["title"],["原文 é"])
        XCTAssertEqual(tags["trackNumber"],["03/12"])
        XCTAssertEqual(tags["CUSTOM"],["保留字段"])
        // A count claiming an unbounded number of comments must be rejected without allocation.
        var corrupt = content; corrupt.replaceSubrange(12..<16,with: Data([255,255,255,255]))
        try corrupt.write(to: url); XCTAssertThrowsError(try FLACMetadata.read(url))
        try Data(content.dropLast()).write(to: url); XCTAssertThrowsError(try FLACMetadata.read(url))
    }
}
