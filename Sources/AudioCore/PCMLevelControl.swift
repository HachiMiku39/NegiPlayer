import AVFoundation

/// Metadata gain is separate from the player's 0...1 mixing volume and from tone EQ.
/// Three linear stages cover ReplayGain policy's conservative EQ/peak budget over -288...72 dB without exceeding a unit's range.
public final class PCMLevelControl {
    private let stages=(0..<3).map { _ in AVAudioUnitEQ(numberOfBands:1) }
    public init() { for stage in stages { stage.bands[0].bypass=true } }
    public func connect(engine:AVAudioEngine,from source:AVAudioNode,format:AVAudioFormat)->AVAudioNode {
        var upstream=source
        for stage in stages { engine.attach(stage); engine.connect(upstream,to:stage,format:format); upstream=stage }
        return upstream
    }
    public func apply(gainDB:Float) {
        var remaining=gainDB.isFinite ? min(72,max(-288,gainDB)) : 0
        for stage in stages { let value=min(24,max(-96,remaining)); stage.globalGain=value; remaining-=value }
    }
}

public struct PCMLevelMeasurement:Codable {
    public let gainDB:Float; public let input:Float; public let volume:Float; public let means:[Float]
}
/// Explicit offline verification; generated PCM only, no hardware output.
public enum PCMLevelControlVerification {
    public static func measure() throws -> [PCMLevelMeasurement] {
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        var measurements:[PCMLevelMeasurement]=[]
        for gain:Float in [-180,-96,-6,0,6,30,72] {
            let engine=AVAudioEngine(),player=AVAudioPlayerNode(),level=PCMLevelControl()
            engine.attach(player);let last=level.connect(engine:engine,from:player,format:format);engine.connect(last,to:engine.mainMixerNode,format:format)
            level.apply(gainDB:gain);player.volume=0.5
            try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
            let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192)!;buffer.frameLength=8192
            let input:Float=0.0001
            for c in 0..<2 { for i in 0..<8192 { buffer.floatChannelData![c][i]=input } }
            player.scheduleBuffer(buffer);try engine.start();player.play();defer{engine.stop()}
            let result=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
            guard try engine.renderOffline(4096,to:result) == .success else { throw CocoaError(.coderInvalidValue) }
            let means=(0..<2).map { c -> Float in var sum:Float=0;for i in 512..<4096 { sum+=result.floatChannelData![c][i] };return sum/3584 }
            measurements.append(.init(gainDB:gain,input:input,volume:0.5,means:means))
        }
        return measurements
    }
}
