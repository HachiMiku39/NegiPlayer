import Foundation

/// Read only Vorbis Comment metadata; skip artwork and audio payload without decoding/copying.
public enum FLACMetadata {
    public static func read(_ url: URL) throws -> [String: [String]] {
        func invalid() -> NSError { NSError(domain: "FLACMetadata", code: 1, userInfo: [NSLocalizedDescriptionKey: "FLAC 标签结构损坏或超出读取上限"]) }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let length = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { throw invalid() }
        var tags: [String: [String]] = [:]
        while true {
            try Task.checkCancellation()
            let header = try file.read(upToCount: 4) ?? Data()
            guard header.count == 4 else { throw invalid() }
            let size = header.suffix(3).reduce(0) { ($0 << 8) | Int($1) }
            let start = try file.offset()
            guard UInt64(size) <= length-start else { throw invalid() }
            if header[0] & 0x7f == 4 {
                guard size <= 8_000_000 else { throw invalid() }
                let data = try file.read(upToCount: size) ?? Data(); guard data.count == size else { throw invalid() }
                var at = 0
                func uint32() throws -> Int {
                    guard data.count-at >= 4 else { throw invalid() }
                    let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at+$1]) << ($1*8) }
                    at += 4; return Int(value)
                }
                let vendor = try uint32(); guard vendor <= data.count-at else { throw invalid() }; at += vendor
                let count = try uint32(); guard count <= 65_536 else { throw invalid() }
                for _ in 0..<count {
                    let n = try uint32(); guard n <= data.count-at else { throw invalid() }
                    guard let comment = String(data: data[at..<at+n], encoding: .utf8), let split = comment.firstIndex(of: "=") else { throw invalid() }
                    let name = String(comment[..<split]).uppercased(); let value = String(comment[comment.index(after: split)...])
                    guard !name.isEmpty else { throw invalid() }
                    tags[name,default: []].append(value)
                    let alias: String?
                    switch name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "") {
                    case "TITLE": alias = "title"
                    case "ARTIST": alias = "artist"
                    case "ALBUM": alias = "albumName"
                    case "ALBUMARTIST": alias = "albumArtist"
                    case "TRACKNUMBER": alias = "trackNumber"
                    case "DISCNUMBER": alias = "discNumber"
                    default: alias = nil
                    }
                    if let alias { tags[alias,default: []].append(value) }
                    at += n
                }
            }
            try file.seek(toOffset: start+UInt64(size))
            if header[0] & 0x80 != 0 { break }
        }
        return tags
    }
}
