import Foundation

public enum LoudnessMode: String, Codable, CaseIterable, Sendable {
    case off = "关闭"
    case track = "逐曲响度"
    case album = "专辑响度"
}

public struct PlaybackPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var volume: Float = 0.5
    public var volumeLimit: Float = 1
    public var loudnessMode: LoudnessMode = .off
    public var loudnessPreampDB: Float = 0
    public var preventPeakOverload = true
    public var headroomDB: Float = 0
    public var eqEnabled = false
    public var gains: [Float] = Array(repeating: 0, count: 10)
    public var eqPreampDB: Float = -6
    public var presetName = "自定义"
    public var mediaControls = true
    public var preferredDeviceUID: String?
    public init() {}
    public func sanitized() -> Self {
        var s = self
        func bound(_ x: Float, _ low: Float, _ high: Float, _ fallback: Float) -> Float {
            x.isFinite ? min(high, max(low, x)) : fallback
        }
        s.volumeLimit = bound(s.volumeLimit, 0, 1, 1)
        s.volume = bound(s.volume, 0, s.volumeLimit, 0)
        s.loudnessPreampDB = bound(s.loudnessPreampDB, -12, 12, 0)
        s.headroomDB = bound(s.headroomDB, 0, 24, 0)
        s.eqPreampDB = bound(s.eqPreampDB, -24, 0, -6)
        s.gains = (0..<10).map { bound(s.gains.indices.contains($0) ? s.gains[$0] : 0, -12, 12, 0) }
        return s
    }
}

public struct PlaybackPreferencesStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> PlaybackPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let settings = try JSONDecoder().decode(PlaybackPreferences.self, from: data)
        guard settings.version == 1 else { throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "播放设置版本不兼容，已保留原文件"]) }
        return settings.sanitized()
    }
    public func save(_ value: PlaybackPreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value.sanitized()).write(to: url, options: .atomic)
    }
}

public struct LoudnessAdjustment: Equatable, Sendable {
    public var gainDB: Float
    public var status: String
    public var peakLimited: Bool
}

/// Reads existing ReplayGain metadata. No measurement, tag writing, limiter or true-peak claim.
public enum LoudnessPolicy {
    public static func adjustment(tags: [String: [String]], settings: PlaybackPreferences) -> LoudnessAdjustment {
        let s = settings.sanitized()
        guard s.loudnessMode != .off else { return .init(gainDB: -s.headroomDB, status: "响度统一已关闭", peakLimited: false) }
        var canonical: [String: [String]] = [:]
        for key in tags.keys.sorted() { canonical[key.uppercased(), default: []] += tags[key] ?? [] }
        func number(_ key: String, gain: Bool) -> Double? {
            for raw in canonical[key] ?? [] {
                var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if gain && text.lowercased().hasSuffix("db") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
                if let value = Double(text), value.isFinite, gain ? (-60...60).contains(value) : (value > 0 && value <= 64) { return value }
            }
            return nil
        }
        var prefix = s.loudnessMode == .album ? "REPLAYGAIN_ALBUM" : "REPLAYGAIN_TRACK"
        var gain = number(prefix+"_GAIN", gain: true)
        var fallback = false
        if gain == nil && s.loudnessMode == .album {
            prefix = "REPLAYGAIN_TRACK"; gain = number(prefix+"_GAIN", gain: true); fallback = gain != nil
        }
        guard let gain else { return .init(gainDB: -s.headroomDB, status: "无有效 ReplayGain 标签，未自动调整响度", peakLimited: false) }
        // Reserve headroom before the optional EQ as well as after metadata normalization.
        var applied = Float(gain) + s.loudnessPreampDB - s.headroomDB
        var limited = false
        if s.preventPeakOverload, let peak = number(prefix+"_PEAK", gain: false) {
            let eqBudget = s.eqEnabled ? max(0, s.gains.filter { $0 > 0 }.reduce(0,+) + s.eqPreampDB) : 0
            let ceiling = Float(-20 * log10(peak)) - eqBudget - s.headroomDB
            if applied > ceiling { applied = ceiling; limited = true }
        }
        applied = min(24, max(-96, applied))
        let kind = fallback ? "专辑标签缺失，使用逐曲标签" : (s.loudnessMode == .album ? "使用专辑 ReplayGain" : "使用逐曲 ReplayGain")
        return .init(gainDB: applied, status: kind + (limited ? " · 按标签峰值限制增益" : ""), peakLimited: limited)
    }
}

public struct EQPreset: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let gains: [Float]
    public let preampDB: Float
    public static let builtIn: [Self] = [
        .init(name: "平直", gains: Array(repeating: 0, count: 10), preampDB: 0),
        .init(name: "人声轻调", gains: [-2,-2,-1,0,1,2,2,1,0,-1], preampDB: -6),
        .init(name: "低频轻调", gains: [3,3,2,1,0,0,0,0,0,0], preampDB: -6),
        .init(name: "柔和高频", gains: [0,0,0,0,0,0,-1,-2,-3,-3], preampDB: -3)
    ]
}
