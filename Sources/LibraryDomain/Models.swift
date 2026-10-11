import Foundation

public struct MediaFile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var rootID: String
    public var relativePath: String
    public var title: String
    public var artists: [String]
    public var albumArtist: String
    public var album: String
    public var codec: String
    public var sampleRate: Double
    public var channels: Int
    public var duration: Double
    public var size: Int64
    public var modified: Double
    public var available: Bool
    public var issue: String?
    public var tags: [String: [String]]
    public var trackNumber: Int
    public var discNumber: Int
    public var releaseKey: String
    public var audioIdentity: String? = nil
    public var metadataVersion: Int? = nil

    public init(id: String = UUID().uuidString, rootID: String, relativePath: String, title: String,
                artists: [String] = [], albumArtist: String = "", album: String = "", codec: String = "未知",
                sampleRate: Double = 0, channels: Int = 0, duration: Double = 0, size: Int64 = 0,
                modified: Double = 0, available: Bool = true, issue: String? = nil,
                tags: [String: [String]] = [:], trackNumber: Int = 0, discNumber: Int = 1, releaseKey: String = "") {
        self.id = id; self.rootID = rootID; self.relativePath = relativePath; self.title = title
        self.artists = artists; self.albumArtist = albumArtist; self.album = album; self.codec = codec
        self.sampleRate = sampleRate; self.channels = channels; self.duration = duration; self.size = size
        self.modified = modified; self.available = available; self.issue = issue; self.tags = tags
        self.trackNumber = trackNumber; self.discNumber = discNumber; self.releaseKey = releaseKey
    }
    public var artistDisplay: String { artists.isEmpty ? "未知艺人" : artists.joined(separator: " · ") }
    public var albumDisplay: String { album.isEmpty ? "未标记专辑" : album }
    public var isDSD: Bool { codec.hasPrefix("DSD") || codec == "DST" }
}

public struct LibraryRoot: Identifiable, Codable, Sendable {
    public var id: String
    public var path: String
    public var bookmark: Data
    public var status: String
    public init(id: String = UUID().uuidString, path: String, bookmark: Data, status: String = "在线") {
        self.id = id; self.path = path; self.bookmark = bookmark; self.status = status
    }
}

public enum FileJobPhase: String, Codable, Sendable {
    case planned, copied, verified, fileCommitted, databaseCommitted, recoveryRequired, failed
}

public struct FileJob: Codable, Sendable {
    public var id: String = UUID().uuidString
    public var mediaID: String
    public var phase: FileJobPhase = .planned
    public var source: String
    public var destination: String
}

public protocol WaveformAnalyzing: Sendable {
    // Analysis is independent of the output graph. Never feed this PCM into DoP.
    func peaks(for url: URL, bins: Int) async throws -> [Float]
}
