import Foundation
import Darwin

/// Optional native decoder for formats not accepted by AVAudioConverter.
/// Only analysis PCM travels through this pipe; playback DSP is independent.
enum SensMeFFmpegDecoder {
    static var executable: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Tools/ffmpeg"),
            Bundle.main.resourceURL?.appendingPathComponent("ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult
    static func forEachBuffer(source: URL, executable: URL, timeout: TimeInterval = 180,
                              consume: (UnsafeBufferPointer<Int16>) throws -> Bool) throws -> Int64 {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EnrichmentError("此音频需要本机 FFmpeg 解码器")
        }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = ["-nostdin", "-v", "error", "-threads", "1", "-i", source.path,
                             "-map", "0:a:0", "-vn", "-sn", "-dn", "-ac", "2", "-ar", "44100",
                             "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        try Task.checkCancellation()
        try process.run()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        let stdout = output.fileHandleForReading.fileDescriptor, stderr = errors.fileHandleForReading.fileDescriptor
        for fd in [stdout, stderr] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw EnrichmentError("无法读取音频解码管道")
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var descriptors = [pollfd(fd: stdout, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: stderr, events: Int16(POLLIN), revents: 0)]
        var raw = [UInt8](repeating: 0, count: 65536), samples = [Int16](repeating: 0, count: 32768)
        var pending = Data(), diagnostic = Data(), frames: Int64 = 0
        while descriptors.contains(where: { $0.fd >= 0 }) {
            try Task.checkCancellation()
            guard Date() < deadline else { throw EnrichmentError("音频解码响应超时") }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw EnrichmentError("无法读取音频解码管道")
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = raw.withUnsafeMutableBytes { read(descriptors[index].fd, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    throw EnrichmentError("无法读取音频解码管道")
                }
                if count == 0 { descriptors[index].fd = -1; continue }
                if index == 1 {
                    diagnostic.append(contentsOf: raw.prefix(count))
                    if diagnostic.count > 8192 { diagnostic.removeFirst(diagnostic.count - 8192) }
                    continue
                }
                pending.append(contentsOf: raw.prefix(count))
                let bytes = pending.count / 4 * 4
                if bytes > 0 {
                    _ = samples.withUnsafeMutableBytes { destination in pending.copyBytes(to: destination.bindMemory(to: UInt8.self), count: bytes) }
                    let keepGoing = try samples.withUnsafeBufferPointer { buffer in
                        try consume(UnsafeBufferPointer(rebasing: buffer.prefix(bytes / 2)))
                    }
                    frames += Int64(bytes / 4); pending.removeFirst(bytes)
                    if !keepGoing {
                        if !process.isRunning && process.terminationStatus != 0 {
                            throw failure(process.terminationStatus, diagnostic)
                        }
                        return frames
                    }
                }
            }
        }
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw EnrichmentError("音频解码响应超时") }
            usleep(10_000)
        }
        guard process.terminationStatus == 0 else { throw failure(process.terminationStatus, diagnostic) }
        guard pending.isEmpty else { throw EnrichmentError("音频解码未产生完整的 PCM 帧") }
        guard frames > 0 else { throw EnrichmentError("音频没有有效 PCM 帧") }
        return frames
    }

    private static func failure(_ code: Int32, _ diagnostic: Data) -> EnrichmentError {
        let detail = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return EnrichmentError("FFmpeg (\(code))" + (detail.isEmpty ? "" : ": \(detail)"))
    }
}
