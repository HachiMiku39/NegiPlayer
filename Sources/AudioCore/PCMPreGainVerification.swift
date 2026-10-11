import Foundation
import AVFoundation

public struct PCMPreGainReport: Codable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var inputAmplitude: Float
    public var gainDB: Float
    public var bypassMean: Float
    public var processedMean: Float
    public var source: String
}

/// Explicit validation only; original synthetic PCM, no audio device output or source files.
public enum PCMPreGainVerification {
    public static func measure() throws -> PCMPreGainReport {
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        func render(_ gain: Float, bypass: Bool) throws -> Float {
            let engine = AVAudioEngine(); let player = AVAudioPlayerNode(); let unit = AVAudioUnitEQ(numberOfBands:1)
            unit.bands[0].bypass = true; unit.globalGain = gain; unit.bypass = bypass
            engine.attach(player); engine.attach(unit); engine.connect(player,to:unit,format:format); engine.connect(unit,to:engine.mainMixerNode,format:format)
            try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
            let source = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192)!; source.frameLength = 8192
            for channel in 0..<2 { for i in 0..<8192 { source.floatChannelData![channel][i] = 0.25 } }
            player.scheduleBuffer(source); try engine.start(); player.play()
            defer { engine.stop() }
            let result = AVAudioPCMBuffer(pcmFormat:engine.manualRenderingFormat,frameCapacity:4096)!
            var sum: Float = 0; var samples: Float = 0
            for _ in 0..<4 {
                if try engine.renderOffline(4096,to:result) == .success {
                    for channel in 0..<2 { for i in 512..<Int(result.frameLength) { sum += abs(result.floatChannelData![channel][i]); samples += 1 } }
                    if samples > 0 { break }
                }
            }
            guard samples > 0 else { throw NSError(domain:"PCMRender",code:1,userInfo:[NSLocalizedDescriptionKey:"未获得实际渲染帧"]) }
            return sum/samples
        }
        return try .init(sampleRate:48000,channels:2,inputAmplitude:0.25,gainDB:-6,
                         bypassMean:render(0,bypass:true),processedMean:render(-6,bypass:false),source:"AVAudioEngine offline render of original synthetic PCM")
    }
}
