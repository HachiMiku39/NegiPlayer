import Foundation

public enum DoPError: Error { case channelMismatch, unevenChannels, invalidMarker, incompleteFrame }

/// Pure reference packer; the HAL transport implements the same byte layout.
public struct DoPPacker {
    public let channels: Int
    private var marker: UInt8 = 0x05
    private var pending: [[UInt8]]
    public init(channels: Int) { precondition(channels > 0); self.channels = channels; pending = Array(repeating: [], count: channels) }
    public mutating func resetAfterSeek() { marker = 0x05; pending = Array(repeating: [], count: channels) }
    /// Input: chronological MSB-first DSD bytes per channel. Output: little-endian 24-bit DoP.
    public mutating func pack(_ dsd: [[UInt8]], finish: Bool = false, silence: UInt8 = 0x69) throws -> Data {
        guard dsd.count == channels else { throw DoPError.channelMismatch }
        guard Set(dsd.map(\.count)).count == 1 else { throw DoPError.unevenChannels }
        for c in 0..<channels { pending[c].append(contentsOf: dsd[c]) }
        if finish && pending[0].count % 2 != 0 { for c in 0..<channels { pending[c].append(silence) } }
        let frames = pending[0].count / 2
        var out = Data(); out.reserveCapacity(frames * channels * 3)
        for frame in 0..<frames {
            for c in 0..<channels { out.append(pending[c][frame*2+1]); out.append(pending[c][frame*2]); out.append(marker) }
            marker = marker == 0x05 ? 0xFA : 0x05
        }
        for c in 0..<channels { pending[c].removeFirst(frames*2) }
        return out
    }
}

public enum OutputMode: String, Codable { case compatiblePCM, strictPCM, dsdDoP, effectsPCM }
public struct VolumeTransition: Equatable {
    public var mustPause: Bool
    public var softwareGain: Double
    public static func enteringDirect(fromGain: Double, preampDB: Double, verifiedHardwareControl: Bool) -> Self {
        .init(mustPause: (fromGain < 1 || preampDB < 0) && !verifiedHardwareControl, softwareGain: 1)
    }
}

public struct PlaybackAnchor: Equatable {
    public var mediaSeconds: Double
    public var eventUptime: Double
    public var rate: Double
    public var running: Bool
    public init(mediaSeconds: Double, eventUptime: Double, rate: Double = 1, running: Bool) {
        self.mediaSeconds = mediaSeconds; self.eventUptime = eventUptime; self.rate = rate; self.running = running
    }
    public func mediaTime(at eventUptime: Double) -> Double { mediaSeconds + (running ? (eventUptime-self.eventUptime)*rate : 0) }
}
