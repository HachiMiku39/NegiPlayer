import Foundation

public enum MetadataField: String, Codable, CaseIterable, Sendable, Identifiable {
    case title = "TITLE", artist = "ARTIST", album = "ALBUM", albumArtist = "ALBUMARTIST"
    case track = "TRACKNUMBER", trackTotal = "TRACKTOTAL", disc = "DISCNUMBER", discTotal = "DISCTOTAL"
    case year = "DATE", originalYear = "ORIGINALDATE", genre = "GENRE", label = "LABEL"
    case composer = "COMPOSER", lyricist = "LYRICIST", conductor = "CONDUCTOR", copyright = "COPYRIGHT"
    case isrc = "ISRC", barcode = "BARCODE", catalogNumber = "CATALOGNUMBER", language = "LANGUAGE"
    case compilation = "COMPILATION", artistOrigin = "ARTIST_ORIGIN", artistEra = "ARTIST_ERA", artistType = "ARTIST_TYPE"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .title: return "标题"
        case .artist: return "艺人"
        case .album: return "专辑"
        case .albumArtist: return "专辑艺人"
        case .track: return "曲号"
        case .trackTotal: return "总曲数"
        case .disc: return "碟号"
        case .discTotal: return "总碟数"
        case .year: return "发行年份"
        case .originalYear: return "原始年份"
        case .genre: return "流派"
        case .label: return "唱片公司"
        case .composer: return "作曲"
        case .lyricist: return "作词"
        case .conductor: return "指挥"
        case .copyright: return "版权"
        case .isrc: return "ISRC"
        case .barcode: return "条形码"
        case .catalogNumber: return "发行编号"
        case .language: return "语言"
        case .compilation: return "合辑"
        case .artistOrigin: return "艺人来源地"
        case .artistEra: return "艺人活跃年代"
        case .artistType: return "艺人类型"
        }
    }
}

public struct MetadataPatch: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var track: String
    public var disc: String
    public var year: String
    public var genre: String
    public var gracenoteID: String
    public var additionalFields: [String: String]
    public init(title: String = "", artist: String = "", album: String = "", track: String = "", disc: String = "", year: String = "", genre: String = "", gracenoteID: String = "", additionalFields: [String: String] = [:]) {
        self.title = title; self.artist = artist; self.album = album; self.track = track; self.disc = disc; self.year = year; self.genre = genre; self.gracenoteID = gracenoteID; self.additionalFields = additionalFields
    }
    private enum CodingKeys: String, CodingKey { case title, artist, album, track, disc, year, genre, gracenoteID, additionalFields }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""; artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""; track = try c.decodeIfPresent(String.self, forKey: .track) ?? ""
        disc = try c.decodeIfPresent(String.self, forKey: .disc) ?? ""; year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""; gracenoteID = try c.decodeIfPresent(String.self, forKey: .gracenoteID) ?? ""
        additionalFields = try c.decodeIfPresent([String: String].self, forKey: .additionalFields) ?? [:]
    }
    public subscript(_ field: MetadataField) -> String {
        get {
            switch field {
            case .title: return title
            case .artist: return artist
            case .album: return album
            case .track: return track
            case .disc: return disc
            case .year: return year
            case .genre: return genre
            default: return additionalFields[field.rawValue] ?? ""
            }
        }
        set {
            switch field {
            case .title: title = newValue
            case .artist: artist = newValue
            case .album: album = newValue
            case .track: track = newValue
            case .disc: disc = newValue
            case .year: year = newValue
            case .genre: genre = newValue
            default: additionalFields[field.rawValue] = newValue
            }
        }
    }
    public var availableFields: [MetadataField] { MetadataField.allCases.filter { !self[$0].isEmpty } }
    public var isEmpty: Bool { availableFields.isEmpty }
    public func selecting(_ fields: Set<MetadataField>) -> MetadataPatch {
        var result = MetadataPatch(gracenoteID: gracenoteID)
        for field in availableFields where fields.contains(field) { result[field] = self[field] }
        return result
    }
    public func merging(_ newer: MetadataPatch) -> MetadataPatch {
        var result = self
        for field in newer.availableFields { result[field] = newer[field] }
        if !newer.gracenoteID.isEmpty { result.gracenoteID = newer.gracenoteID }
        return result
    }
    public func applying(to media: MediaFile) -> MediaFile {
        var result = media
        if !title.isEmpty { result.title = title; result.tags["title"] = [title] }
        if !artist.isEmpty { result.artists = [artist]; result.tags["artist"] = [artist] }
        if !album.isEmpty { result.album = album; result.tags["albumName"] = [album] }
        if !self[.albumArtist].isEmpty { result.albumArtist = self[.albumArtist]; result.tags["albumArtist"] = [self[.albumArtist]] }
        if let n = Int(track.components(separatedBy: "/")[0]), n > 0 { result.trackNumber = n }
        if let n = Int(disc.components(separatedBy: "/")[0]), n > 0 { result.discNumber = n }
        if !year.isEmpty { result.tags["date"] = [year] }
        if !genre.isEmpty { result.tags["genre"] = [genre] }
        for field in availableFields where additionalFields[field.rawValue] != nil { result.tags[field.rawValue.lowercased()] = [self[field]] }
        return result
    }
    public var vorbisFields: [String: String] {
        Dictionary(uniqueKeysWithValues: availableFields.map { ($0.rawValue, self[$0]) })
    }
}
