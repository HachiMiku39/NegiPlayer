import XCTest
import FileOperations
import CryptoKit
import MediaIO

final class FileOperationTests: XCTestCase {
    func testWAVTagCopyPreservesAudioAndUnknownChunks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func le(_ n: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0*8)) }) }
        func chunk(_ id: String, _ data: Data) -> Data { Data(id.utf8)+le(UInt32(data.count))+data+(data.count%2 == 1 ? Data([0xA7]) : Data()) }
        let pcm = Data([0,0,1,0,255,127,0,128])
        let fmt = Data([1,0,1,0])+le(44100)+le(88200)+Data([2,0,16,0])
        let unknown = chunk("bext", Data("preserve odd size!".utf8))
        let info = Data("INFO".utf8)+chunk("IXXX", Data("private\0".utf8))
        let body = Data("WAVE".utf8)+chunk("fmt ", fmt)+unknown+chunk("LIST", info)+chunk("data", pcm)
        let source = folder.appendingPathComponent("source.wav"); let dest = folder.appendingPathComponent("copy.wav")
        let original = Data("RIFF".utf8)+le(UInt32(body.count))+body; try original.write(to: source)
        let digest = try WAVCopyVerifier.writeValidatedCopy(source: source, destination: dest, fields: ["INAM": "New title", "IART": "AC/DC"])
        // Independent known payload digest, not a second call to the writer's verification routine.
        let expected = SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try AudioIdentity.digest(source), try AudioIdentity.digest(dest))
        let output = try Data(contentsOf: dest)
        XCTAssertNotNil(output.range(of: unknown))
        let tags = try WAVCopyVerifier.info(dest)
        XCTAssertEqual(tags["INAM"], "New title"); XCTAssertEqual(tags["IXXX"], "private")
        XCTAssertThrowsError(try WAVCopyVerifier.writeValidatedCopy(source: source, destination: source, fields: ["INAM":"bad"]))
        XCTAssertThrowsError(try WAVCopyVerifier.writeValidatedCopy(source: source, destination: folder.appendingPathComponent("unsupported.wav"), fields: ["INAM":"中文"]))
    }
}
