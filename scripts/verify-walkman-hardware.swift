import Foundation
import CryptoKit

@main struct HardwareProbe {
    static func main() async throws {
        guard CommandLine.arguments.contains("--write-generated-fixtures") else { fatalError("Explicit fixture flag required") }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("NegiHardware-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        func le(_ n: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        let pcm = Data(repeating: 0, count: 44_100 * 2 / 5)
        let fmt = Data([1,0,1,0]) + le(44100) + le(88200) + Data([2,0,16,0])
        let body = Data("WAVEfmt ".utf8) + le(16) + fmt + Data("data".utf8) + le(UInt32(pcm.count)) + pcm
        let data = Data("RIFF".utf8) + le(UInt32(body.count)) + body
        let source = scratch.appendingPathComponent("NegiPlayer-Generated-Silence.wav")
        try data.write(to: source)
        var report: [[String: Any]] = []
        for name in ["WALKMAN", "SDCARD"] {
            let volume = try WalkmanVolume.inspect(URL(fileURLWithPath: "/Volumes/" + name))
            let testName = "NegiPlayer-Test-" + UUID().uuidString
            let directory = volume.musicDirectory.appendingPathComponent(testName)
            guard !fm.fileExists(atPath: directory.path) else { fatalError("Unique test directory exists") }
            let item = try MusicTransferItem(source: source, relativePath: testName + "/初音测试.wav")
            do {
                let copied = try await MusicTransfer.run(items: [item], musicDirectory: volume.musicDirectory, validateDestination: { try volume.validateMounted() }, progress: { _ in })
                guard copied.copied == 1, try Data(contentsOf: directory.appendingPathComponent("初音测试.wav")) == data else { fatalError("Hardware data mismatch") }
                let skipped = try await MusicTransfer.run(items: [item], musicDirectory: volume.musicDirectory, validateDestination: { try volume.validateMounted() }, progress: { _ in })
                guard skipped.skipped == 1 else { fatalError("Skip failed") }
                let both = try await MusicTransfer.run(items: [item], musicDirectory: volume.musicDirectory, policy: .keepBoth, validateDestination: { try volume.validateMounted() }, progress: { _ in })
                guard both.copied == 1, try Data(contentsOf: directory.appendingPathComponent("初音测试 (2).wav")) == data else { fatalError("Keep both failed") }
                _ = try volume.validateMounted()
                try fm.removeItem(at: directory)
                guard !fm.fileExists(atPath: directory.path) else { fatalError("Cleanup failed") }
                report.append(["volume": name, "model": volume.model, "fixtureBytes": data.count, "copySHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "verified": true, "skipExisting": true, "keepBoth": true, "testDirectoryRemoved": true])
            } catch {
                if (try? volume.validateMounted()) != nil { try? fm.removeItem(at: directory) }
                throw error
            }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
