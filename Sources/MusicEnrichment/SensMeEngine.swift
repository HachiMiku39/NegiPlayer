import Foundation
import AVFoundation
import Darwin
import CSensMeCore

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
        SensMeEngine.isAvailable
    }
    public var gracenoteReady: Bool {
        FileManager.default.isExecutableFile(atPath: wine.path) && FileManager.default.fileExists(atPath: python.path) && FileManager.default.fileExists(atPath: gracenoteDirectory.path)
    }
    public static func windowsPath(_ url: URL) -> String { "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\") }
    public func run(helper: String, arguments: [String], job: URL, timeout: TimeInterval = 180) throws {
        guard gracenoteReady else { throw EnrichmentError("请配置 Gracenote SDK 及其外部运行环境") }
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
        let estimate = Double(audio.length) / audio.processingFormat.sampleRate * 176400
        let capacity = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard estimate < Double(capacity) - 16_777_216 else { throw EnrichmentError("本机临时空间不足，无法分析此曲目") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw EnrichmentError("无法创建分析临时文件") }
        let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
        return try convert(audio) { samples in
            try file.write(contentsOf: Data(bytes: samples.baseAddress!, count: samples.count * 2))
            return true
        }
    }

    /// Buffers are borrowed for this synchronous call. Return false to finish
    /// at the native analysis window without writing a temporary PCM file.
    public static func forEachBuffer(source: URL, consume: (UnsafeBufferPointer<Int16>) throws -> Bool) throws -> Int64 {
        let audio = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        return try convert(audio, consume: consume)
    }

    private static func convert(_ audio: AVAudioFile, consume: (UnsafeBufferPointer<Int16>) throws -> Bool) throws -> Int64 {
        guard (1...2).contains(audio.processingFormat.channelCount), audio.length > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: audio.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw EnrichmentError("此音频不能转换为 SensMe 所需的 PCM") }
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
                frames += Int64(output.frameLength)
                if try !consume(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Int16.self), count: Int(output.frameLength) * 2)) {
                    finished = true
                }
            }
            switch status {
            case .endOfStream: finished = true
            case .error: throw EnrichmentError("音频转换失败")
            default: break
            }
        }
        guard frames > 0 else { throw EnrichmentError("音频没有有效 PCM 帧") }
        return frames
    }
}

public enum SensMeEngine {
    public static let version = "NegiSensMe 1.6.1-native.2"
    public static let isAvailable = true

    public static func analyze(source: URL) throws -> CachedSensMe {
        try analyze(source: source, ffmpeg: SensMeFFmpegDecoder.executable)
    }

    public static func analyze(source: URL, ffmpeg: URL?) throws -> CachedSensMe {
        let before = try SourceDigest.sha256(source)
        let blob: Data
        if ["dsf", "dff"].contains(source.pathExtension.lowercased()) {
            guard let ffmpeg else { throw EnrichmentError("此音频需要本机 FFmpeg 解码器") }
            blob = try analyzePCM { consume in try SensMeFFmpegDecoder.forEachBuffer(source: source, executable: ffmpeg, consume: consume) }
        } else {
            do {
                blob = try analyzePCM { consume in try SensMePCM.forEachBuffer(source: source, consume: consume) }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NativeAnalysisFailure {
                throw error
            } catch {
                guard let ffmpeg else { throw error }
                // A failed AV decode may have already fed PCM. The new call
                // owns a fresh analyzer instead of mixing decoder histories.
                blob = try analyzePCM { consume in try SensMeFFmpegDecoder.forEachBuffer(source: source, executable: ffmpeg, consume: consume) }
            }
        }
        try Task.checkCancellation()
        guard try SourceDigest.sha256(source) == before else { throw EnrichmentError("分析期间源文件改变，请重新分析") }
        return try CachedSensMe(sourceSHA256: before, engineVersion: version, blob: blob)
    }

    private struct NativeAnalysisFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func analyzePCM(_ decode: ((UnsafeBufferPointer<Int16>) throws -> Bool) throws -> Int64) throws -> Data {
        guard let analyzer = negi_sensme_analyzer_create() else { throw NativeAnalysisFailure(message: "无法创建原生 SensMe 分析器") }
        defer { negi_sensme_analyzer_destroy(analyzer) }
        var pending = [Int16](repeating: 0, count: 8192), pendingFrames = 0
        _ = try decode { samples in
            var at = 0
            while at < samples.count / 2 {
                try Task.checkCancellation()
                let count = min(4096 - pendingFrames, samples.count / 2 - at)
                pending.withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.advanced(by: pendingFrames * 2).update(from: samples.baseAddress!.advanced(by: at * 2), count: count * 2)
                }
                pendingFrames += count; at += count
                if pendingFrames == 4096 {
                    guard negi_sensme_analyzer_write(analyzer, pending, pendingFrames) != 0 else { throw NativeAnalysisFailure(message: "原生 SensMe 音频处理失败") }
                    pendingFrames = 0
                    if negi_sensme_analyzer_needs_pcm(analyzer) == 0 { return false }
                }
            }
            return true
        }
        if pendingFrames > 0 {
            guard negi_sensme_analyzer_write(analyzer, pending, pendingFrames) != 0 else { throw NativeAnalysisFailure(message: "原生 SensMe 音频处理失败") }
        }
        try Task.checkCancellation()
        let size = negi_sensme_analyzer_finish(analyzer, nil, 0, nil)
        guard size > 0, size <= 200000 else { throw NativeAnalysisFailure(message: "原生 SensMe 分析未能生成结果") }
        var bytes = [UInt8](repeating: 0, count: size)
        guard negi_sensme_analyzer_finish(analyzer, &bytes, bytes.count, nil) == size else { throw NativeAnalysisFailure(message: "原生 SensMe 分析未能生成结果") }
        try Task.checkCancellation()
        return Data(bytes)
    }

    /// Source-compatible bridge for callers of the former external backend.
    /// The native analysis ignores the old runtime and working directory.
    public static func analyze(source: URL, runtime: EnrichmentRuntime, workingDirectory: URL) throws -> CachedSensMe {
        try analyze(source: source)
    }
}
