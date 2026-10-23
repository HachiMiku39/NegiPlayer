import Foundation
import AVFoundation
import CryptoKit

// Build together with SMFMF.swift and SensMeEngine.swift; see sensme-library.py.
@main struct DecodeCommand {
    static func main() {
        do { try decode() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    static func decode() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw EnrichmentError("Expected source and PCM destination") }
        let source = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let start = Date(), hash = try SourceDigest.sha256(source), hashed = Date()
        let frames = try SensMePCM.decode(source: source, destination: output)
        let decoded = Date()
        guard try SourceDigest.sha256(source) == hash else { throw EnrichmentError("Source changed during decode") }
        let value: [String: Any] = ["sourceSHA256": hash, "frames": frames,
                                  "hashSeconds": hashed.timeIntervalSince(start),
                                  "decodeSeconds": decoded.timeIntervalSince(hashed),
                                  "totalSeconds": Date().timeIntervalSince(start)]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
}
