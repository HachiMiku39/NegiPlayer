import Foundation
import AVFoundation
import LibraryDomain

public struct PCMAnalysis: WaveformAnalyzing {
    public init() {}
    public func peaks(for url: URL, bins: Int) async throws -> [Float] {
        let task = Task<[Float], Error>.detached(priority: .utility) {
            guard bins > 0, bins <= 4096 else { return [] }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return [] }
            var peaks = [Float](repeating: 0, count: bins); var cursor: Int64 = 0
            while cursor < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for frame in 0..<Int(buffer.frameLength) {
                    let bin = min(bins-1, Int((cursor+Int64(frame))*Int64(bins)/file.length))
                    for channel in 0..<Int(buffer.format.channelCount) { peaks[bin] = max(peaks[bin], abs(channels[channel][frame])) }
                }
                cursor += Int64(buffer.frameLength)
            }
            return peaks
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
