import XCTest
import MediaIO
import AVFoundation

final class ProbeTests: XCTestCase {
    func testGeneratedCodecCorpus() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEGI_FIXTURES"] else { throw XCTSkip("Run generate-fixtures.py and set NEGI_FIXTURES for the codec corpus") }
        let folder = URL(fileURLWithPath: path)
        var nativeResults: [[String: Any]] = []
        if let report = ProcessInfo.processInfo.environment["NEGI_NATIVE_REPORT"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: report))
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            nativeResults = parsed?["results"] as? [[String: Any]] ?? []
            XCTAssertEqual(parsed?["application"] as? String,"NegiPlayer")
        }
        let expectations: [(String, String)] = [
            ("01 PCM Verification.wav","PCM 16-bit"), ("02 MP3 Verification.mp3","MP3"),
            ("03 FLAC Verification.flac","FLAC"), ("04 AAC Verification.m4a","AAC"),
            ("05 ALAC Verification.m4a","ALAC"), ("06 DSD64 Verification.dsf","DSD (DSF)"),
            ("07 Raw DFF Verification.dff","DSD (DFF)")
        ]
        for (name, codec) in expectations {
            let url = folder.appendingPathComponent(name)
            let probe: (codec: String, rate: Double, channels: Int, duration: Double)
            do { probe = try MediaProbe.detect(url) }
            catch { XCTFail("Probe failed for \(name): \(error)"); continue }
            XCTAssertEqual(probe.codec,codec,name); XCTAssertEqual(probe.channels,2,name); XCTAssertGreaterThan(probe.duration,0,name)
            XCTAssertTrue(try AudioIdentity.digest(url).hasPrefix("payload-sha256:"))
            if !codec.hasPrefix("DSD") {
                if !nativeResults.isEmpty {
                    let result = try XCTUnwrap(nativeResults.first { $0["file"] as? String == name })
                    XCTAssertEqual(result["decodeStatus"] as? String,"passed",name)
                    XCTAssertGreaterThan(result["decodedFrames"] as? Int ?? 0,0,name)
                    XCTAssertEqual(result["audioIdentity"] as? String,try AudioIdentity.digest(url),name)
                    continue
                }
                let file: AVAudioFile
                do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
                catch { XCTFail("Decode open failed for \(name): \(error)"); continue }
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                try file.read(into: buffer)
                XCTAssertGreaterThan(buffer.frameLength,0,name)
                XCTAssertNotNil(buffer.floatChannelData,name)
            }
        }
        let metadata = await MediaProbe.metadata(folder.appendingPathComponent("05 ALAC Verification.m4a"))
        XCTAssertEqual(metadata["albumArtist"]?.first,"NegiPlayer Test Signal")
        let flacTags = try FLACMetadata.read(folder.appendingPathComponent("03 FLAC Verification.flac"))
        XCTAssertEqual(flacTags["albumArtist"]?.first,"NegiPlayer Test Signal")
        XCTAssertEqual(flacTags["title"]?.first,"FLAC Verification")
        let peaks = try await PCMAnalysis().peaks(for: folder.appendingPathComponent("01 PCM Verification.wav"), bins: 128)
        XCTAssertEqual(peaks.count,128); XCTAssertGreaterThan(peaks.max() ?? 0,0)
    }
    func testRejectsCorruptPayloadBounds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x66,0x4c,0x61,0x43,0x80,0xff,0xff,0xff]).write(to: url)
        XCTAssertThrowsError(try AudioIdentity.digest(url))
    }
}
