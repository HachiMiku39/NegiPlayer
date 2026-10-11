import Foundation

public enum SourceRateFilter: String, CaseIterable, Sendable {
    case all = "全部采样率", hz44100 = "44.1 kHz", hz48000 = "48 kHz", pcmHigh = "≥88.2 kHz PCM", dsd = "DSD"
}
public enum AvailabilityFilter: String, CaseIterable, Sendable {
    case all = "全部状态", online = "文件可用", offline = "文件离线", issue = "有提示"
}
public enum TrackSort: String, CaseIterable, Sendable {
    case path = "文件路径", title = "标题", artist = "艺人", album = "专辑", track = "碟片／曲号", rate = "采样率", duration = "时长"
}

/// Pure query; it filters indexed source fields without changing files or the playback queue.
public struct BrowseQuery: Sendable {
    public var text = ""
    public var codec = ""
    public var sourceRate: SourceRateFilter = .all
    public var availability: AvailabilityFilter = .all
    public var sort: TrackSort = .path
    public var ascending = true
    public init() {}
    public var isDefault: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && codec.isEmpty && sourceRate == .all && availability == .all && sort == .path && ascending
    }
    public func apply(to files: [MediaFile]) -> [MediaFile] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = files.filter { f in
            guard codec.isEmpty || f.codec == codec else { return false }
            switch sourceRate {
            case .all: break
            case .hz44100: guard !f.isDSD, abs(f.sampleRate-44100) < 1 else { return false }
            case .hz48000: guard !f.isDSD, abs(f.sampleRate-48000) < 1 else { return false }
            case .pcmHigh: guard !f.isDSD, f.sampleRate >= 88200 else { return false }
            case .dsd: guard f.isDSD else { return false }
            }
            switch availability {
            case .all: break
            case .online: guard f.available else { return false }
            case .offline: guard !f.available else { return false }
            case .issue: guard f.issue != nil else { return false }
            }
            return q.isEmpty || [f.title, f.artistDisplay, f.album, f.relativePath, f.tags.values.flatMap { $0 }.joined(separator: " ")].joined(separator: " ").localizedStandardContains(q)
        }
        result.sort { a, b in
            let order: ComparisonResult
            switch sort {
            case .path: order = a.relativePath.localizedStandardCompare(b.relativePath)
            case .title: order = a.title.localizedStandardCompare(b.title)
            case .artist: order = a.artistDisplay.localizedStandardCompare(b.artistDisplay)
            case .album: order = a.albumDisplay.localizedStandardCompare(b.albumDisplay)
            case .track:
                if a.discNumber != b.discNumber { order = a.discNumber < b.discNumber ? .orderedAscending : .orderedDescending }
                else { order = a.trackNumber == b.trackNumber ? .orderedSame : (a.trackNumber < b.trackNumber ? .orderedAscending : .orderedDescending) }
            case .rate: order = a.sampleRate == b.sampleRate ? .orderedSame : (a.sampleRate < b.sampleRate ? .orderedAscending : .orderedDescending)
            case .duration: order = a.duration == b.duration ? .orderedSame : (a.duration < b.duration ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return ascending ? a.id < b.id : a.id > b.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return result
    }
}

public enum QueuePlan {
    /// The preview queue contains each media version once. Scheduling an existing item next moves it.
    public static func inserting(_ item: MediaFile, into queue: [MediaFile], currentID: String?, next: Bool) -> [MediaFile] {
        if item.id == currentID { return queue }
        if !next, queue.contains(where: { $0.id == item.id }) { return queue }
        var result = queue.filter { $0.id != item.id }
        let index = next ? currentID.flatMap { id in result.firstIndex(where: { $0.id == id }).map { $0+1 } } ?? 0 : result.count
        result.insert(item, at: index)
        return result
    }
}
