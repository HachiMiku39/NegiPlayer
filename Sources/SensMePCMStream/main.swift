import Foundation
import MusicEnrichment

// Raw PCM stdout is intentionally separate from diagnostics on stderr.
// The queue owns source hashes, timeouts, cancellation and native analysis.
do {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--validate-cache" {
        struct Envelope: Decodable {
            let mediaID: String
            let sourceSHA256: String
            let sensme: CachedSensMe?
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        var checked = 0, noTempo = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            let record = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
            guard let result = record.sensme else { continue }
            guard result.engineVersion == SensMeEngine.version else { continue }
            guard result.sourceSHA256 == record.sourceSHA256, result.hasValidBlobChecksum else {
                throw EnrichmentError("Invalid native cache: " + record.mediaID)
            }
            checked += 1; if result.summary.bpm == nil { noTempo += 1 }
        }
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject:
            ["checked": checked, "withoutTempo": noTempo, "engineVersion": SensMeEngine.version, "invalid": 0], options: [.sortedKeys]))
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--analyze" {
        let result = try SensMeEngine.analyze(source: URL(fileURLWithPath: CommandLine.arguments[2]))
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(result))
    } else {
        guard CommandLine.arguments.count == 2 else { throw EnrichmentError("Expected one source audio path") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        _ = try SensMePCM.forEachBuffer(source: source) { samples in
            try FileHandle.standardOutput.write(contentsOf: Data(bytes: samples.baseAddress!, count: samples.count * 2))
            return true
        }
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
