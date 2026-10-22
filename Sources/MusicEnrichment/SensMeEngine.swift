import Foundation
import AVFoundation
import Darwin

public struct EnrichmentRuntime: Sendable {
    public let directory: URL
    public let prefix: URL
    public let helpers: URL
    public var wine: URL { directory.appendingPathComponent("Wine Devel.app/Contents/Resources/wine/bin/wine") }
    public var python: URL { directory.appendingPathComponent("python-win32/python.exe") }
    public var sensmeDLL: URL { directory.appendingPathComponent("SensMe/MMLib11.dll") }
    public var gracenoteDirectory: URL { directory.appendingPathComponent("Gracenote") }
    public init(directory: URL, prefix: URL, helpers: URL) { self.directory = directory; self.prefix = prefix; self.helpers = helpers }
    public var sensmeReady: Bool {
        FileManager.default.isExecutableFile(atPath: wine.path) && FileManager.default.fileExists(atPath: python.path) && FileManager.default.fileExists(atPath: sensmeDLL.path)
    }
    public static func windowsPath(_ url: URL) -> String { "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\") }
    public func run(helper: String, arguments: [String], job: URL, timeout: TimeInterval = 180) throws {
        guard sensmeReady else { throw EnrichmentError("请选择包含 Wine、32 位 Python 和 Sony 分析 DLL 的引擎文件夹") }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path; env["WINEDEBUG"] = "-all"; env["MVK_CONFIG_LOG_LEVEL"] = "0"
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree=d;mshtml=d"
        let ready = prefix.appendingPathComponent(".negi-python-ready")
        if !FileManager.default.fileExists(atPath: ready.path) {
            try EnrichmentProcess.run(executable: wine, arguments: [python.path, "-c", "import ctypes; print('runtime_ready')"], environment: env, job: job, timeout: 180)
            try Data("ready".utf8).write(to: ready, options: .atomic)
        }
        try EnrichmentProcess.run(executable: wine, arguments: [python.path, Self.windowsPath(helpers.appendingPathComponent(helper))] + arguments,
                                  environment: env, job: job, timeout: timeout)
    }
}

public enum EnrichmentProcess {
    public static func run(executable: URL, arguments: [String], environment: [String: String]? = nil, job: URL, timeout: TimeInterval) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: job, withIntermediateDirectories: true)
        let outURL = job.appendingPathComponent("stdout.log"), errURL = job.appendingPathComponent("stderr.log")
        fm.createFile(atPath: outURL.path, contents: nil); fm.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL), error = try FileHandle(forWritingTo: errURL)
        defer { try? output.close(); try? error.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.environment = environment; process.standardOutput = output; process.standardError = error
        process.standardInput = FileHandle.nullDevice; process.currentDirectoryURL = job
        try process.run(); let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw EnrichmentError("分析组件响应超时，请重试或检查运行环境") }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
        } catch {
            process.terminate()
            for _ in 0..<10 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); throw error
        }
        guard process.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: errURL)) ?? Data()
            let message = String(decoding: data.suffix(2000), as: UTF8.self)
            throw EnrichmentError("分析组件失败（\(process.terminationStatus)）：\(message)")
        }
    }
}

public enum SensMePCM {
    /// Dedicated analysis decode. Playback EQ, volume and ReplayGain never enter this path.
    public static func decode(source: URL, destination: URL) throws -> Int64 {
        let audio = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard (1...2).contains(audio.processingFormat.channelCount), audio.length > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: audio.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw EnrichmentError("此音频不能转换为 SensMe 所需的 PCM") }
        let estimate = Double(audio.length) / audio.processingFormat.sampleRate * 176400
        let capacity = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard estimate < Double(capacity) - 16_777_216 else { throw EnrichmentError("本机临时空间不足，无法分析此曲目") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw EnrichmentError("无法创建分析临时文件") }
        let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
        var finished = false, readError: Error?, frames: Int64 = 0
        while !finished {
            try Task.checkCancellation(); output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, state in
                do {
                    let remaining = audio.length - audio.framePosition
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    let count = min(min(requested, input.frameCapacity), AVAudioFrameCount(min(remaining, 8192)))
                    try audio.read(into: input, frameCount: count)
                    state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch { readError = error; state.pointee = .noDataNow; return nil }
            }
            if let readError { throw readError }; if let error { throw error }
            if output.frameLength > 0, let pointer = output.audioBufferList.pointee.mBuffers.mData {
                try file.write(contentsOf: Data(bytes: pointer, count: Int(output.frameLength) * 4)); frames += Int64(output.frameLength)
            }
            switch status {
            case .endOfStream: finished = true
            case .error: throw EnrichmentError("音频转换失败")
            default: break
            }
        }
        guard frames >= 44100 * 10 else { throw EnrichmentError("音频过短，SensMe 至少需要约 10 秒有效音频") }
        return frames
    }
}

public enum SensMeEngine {
    public static func analyze(source: URL, runtime: EnrichmentRuntime, workingDirectory: URL) throws -> CachedSensMe {
        guard runtime.sensmeReady else { throw EnrichmentError("SensMe 引擎尚未配置") }
        let fm = FileManager.default, job = workingDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: job, withIntermediateDirectories: true); defer { try? fm.removeItem(at: job) }
        let before = try SourceDigest.sha256(source)
        let pcm = job.appendingPathComponent("analysis.s16le"), blob = job.appendingPathComponent("analysis.smfmf"), summary = job.appendingPathComponent("analysis.json")
        _ = try SensMePCM.decode(source: source, destination: pcm)
        let wp = EnrichmentRuntime.windowsPath
        try runtime.run(helper: "sensme_analyze_windows.py", arguments: ["--dll", wp(runtime.sensmeDLL), "--pcm", wp(pcm), "--out", wp(blob), "--json", wp(summary)], job: job)
        try Task.checkCancellation()
        guard try SourceDigest.sha256(source) == before else { throw EnrichmentError("分析期间源文件改变，请重新分析") }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: summary)) as? [String: Any]
        return try CachedSensMe(sourceSHA256: before, engineVersion: json?["engine_version"] as? String ?? "Sony MMLib11", blob: Data(contentsOf: blob))
    }
}
