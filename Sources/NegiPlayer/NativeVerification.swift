import Foundation
import AVFoundation
import MediaIO
import AudioCore

/// Explicit development command. Reads only the given generated corpus; never runs on launch by default.
enum NativeVerification {
    struct Request: Codable {
        var fixtures: String; var report: String; var dataDirectory: String
        var realSamples: String?; var realReport: String?
    }
    static var developmentRequest: Request? {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "VerificationRequest", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Request.self, from: data)
        #else
        return nil
        #endif
    }
    static func runIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        let folder: URL; let reportURL: URL
        if let i = args.firstIndex(of: "--verify-fixtures"), args.indices.contains(i+1),
           let r = args.firstIndex(of: "--report"), args.indices.contains(r+1) {
            folder = URL(fileURLWithPath: args[i+1]); reportURL = URL(fileURLWithPath: args[r+1])
        } else if let request = developmentRequest {
            folder = URL(fileURLWithPath: request.fixtures); reportURL = URL(fileURLWithPath: request.report)
        } else { return }
        let names = ["01 PCM Verification.wav","02 MP3 Verification.mp3","03 FLAC Verification.flac","04 AAC Verification.m4a","05 ALAC Verification.m4a","06 DSD64 Verification.dsf","07 Raw DFF Verification.dff"]
        await verify(names.map { folder.appendingPathComponent($0) }, reportURL: reportURL)
        do {
            let dsp = try PCMPreGainVerification.measure()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(dsp).write(to:reportURL.deletingPathExtension().appendingPathExtension("dsp.json"),options:.atomic)
        } catch { NSLog("Native DSP verification failed: %@",error.localizedDescription) }
        if let request = developmentRequest, let samples = request.realSamples, let report = request.realReport,
           let data = try? Data(contentsOf: URL(fileURLWithPath: samples)), let paths = try? JSONDecoder().decode([String].self, from: data) {
            await verify(paths.map { URL(fileURLWithPath: $0) }, reportURL: URL(fileURLWithPath: report))
        }
    }
    private static func verify(_ urls: [URL], reportURL: URL) async {
        var results: [[String: Any]] = []
        for url in urls {
            var row: [String: Any] = ["file": url.lastPathComponent]
            do {
                let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let p = try MediaProbe.detect(url)
                row["codec"] = p.codec; row["channels"] = p.channels; row["duration"] = p.duration; row["sampleRate"] = p.rate
                row["audioIdentity"] = try AudioIdentity.digest(url)
                if !p.codec.hasPrefix("DSD") && p.codec != "DST" {
                    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                    try file.read(into: buffer); row["decodedFrames"] = Int(buffer.frameLength)
                    row["decodeStatus"] = "passed"
                } else { row["decodeStatus"] = "not-connected" }
                let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                row["sourceStatUnchanged"] = before.fileSize == after.fileSize && before.contentModificationDate == after.contentModificationDate
                row["probeStatus"] = "passed"
            } catch { row["error"] = error.localizedDescription; row["probeStatus"] = "failed" }
            results.append(row)
        }
        let report: [String: Any] = ["application":"NegiPlayer", "platform":ProcessInfo.processInfo.operatingSystemVersionString,
                                    "context":"Launched native app; read-only source; real AVAudioFile decoding; no DAC assertion", "results":results]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: reportURL, options: .atomic)
        } catch { NSLog("Native verification report failed: %@", error.localizedDescription) }
    }
}
