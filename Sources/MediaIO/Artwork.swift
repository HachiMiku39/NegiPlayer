import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public struct ArtworkResult: Sendable {
    public let data: Data
    public let source: String
}

/// Bounded, read-only embedded picture readers. No tag editor or network service is required.
public enum EmbeddedArtwork {
    public static let maximumBytes = 24 * 1024 * 1024
    public static func read(_ url: URL) throws -> Data? {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        let length = try h.seekToEnd(); try h.seek(toOffset: 0)
        let head = try h.read(upToCount: 128) ?? Data()
        if head.starts(with: Data("fLaC".utf8)) { return try flac(h, length: length) }
        if head.starts(with: Data("ID3".utf8)) { return try id3(h, at: 0, limit: length) }
        if head.starts(with: Data("RIFF".utf8)), head.count >= 12, head[8..<12] == Data("WAVE".utf8) {
            var at: UInt64 = 12
            for _ in 0..<4096 {
                guard at + 8 <= length else { break }
                let chunk = try read(h, at: at, count: 8)
                let n = UInt64(little(chunk[4..<8])); let start = at + 8
                guard n <= length-start else { return nil }
                if String(decoding: chunk.prefix(4), as: UTF8.self).lowercased() == "id3 " { return try id3(h, at: start, limit: start+n) }
                at = start+n+(n & 1)
            }
        }
        if head.starts(with: Data("DSD ".utf8)), head.count >= 28 {
            let at = head[20..<28].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset*8) }
            if at > 0, at < length { return try id3(h, at: at, limit: length) }
        }
        if ["m4a", "mp4"].contains(url.pathExtension.lowercased()) {
            var budget = 8192
            return try mp4(h, start: 0, end: length, depth: 0, inCover: false, budget: &budget)
        }
        return nil
    }
    private static func read(_ h: FileHandle, at: UInt64, count: Int) throws -> Data {
        try h.seek(toOffset: at); let d = try h.read(upToCount: count) ?? Data()
        guard d.count == count else { throw NSError(domain: "Artwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "封面标签被截断"]) }
        return d
    }
    private static func big(_ d: Data) -> UInt64 { d.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func little(_ d: Data) -> UInt64 { d.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset*8) } }
    private static func sync(_ d: Data) -> Int? {
        guard d.count == 4, d.allSatisfy({ $0 < 128 }) else { return nil }
        return d.reduce(0) { ($0 << 7) | Int($1) }
    }
    private static func flac(_ h: FileHandle, length: UInt64) throws -> Data? {
        var at: UInt64 = 4; var other: Data?
        for _ in 0..<4096 {
            guard at+4 <= length else { return other }
            let header = try read(h, at: at, count: 4); let n = big(header.suffix(3)); at += 4
            guard n <= length-at else { return other }
            if header[0] & 0x7f == 6, n <= UInt64(maximumBytes) {
                let d = try read(h, at: at, count: Int(n)); var i = 0
                func number() -> Int? { guard i+4 <= d.count else { return nil }; defer { i += 4 }; return Int(big(d[i..<i+4])) }
                if let type = number(), let mime = number(), mime <= d.count-i {
                    let linked = String(decoding: d[i..<i+mime], as: UTF8.self) == "-->"; i += mime
                    if let desc = number(), desc <= d.count-i {
                        i += desc
                        if i+16 <= d.count {
                            i += 16
                            if let size = number(), size <= d.count-i, !linked {
                                let picture = Data(d[i..<i+size])
                                if thumbnail(picture) != nil { if type == 3 { return picture }; if other == nil { other = picture } }
                            }
                        }
                    }
                }
            }
            at += n; if header[0] & 0x80 != 0 { return other }
        }
        return other
    }
    private static func deunsync(_ d: Data) -> Data {
        var result = Data(); result.reserveCapacity(d.count); var previous: UInt8 = 0
        for b in d { if previous == 0xff && b == 0 { previous = b; continue }; result.append(b); previous = b }
        return result
    }
    private static func id3(_ h: FileHandle, at: UInt64, limit: UInt64) throws -> Data? {
        guard at+10 <= limit else { return nil }
        let head = try read(h, at: at, count: 10)
        guard head.prefix(3) == Data("ID3".utf8), [2,3,4].contains(head[3]), let size = sync(head[6..<10]), size <= maximumBytes, UInt64(size) <= limit-at-10 else { return nil }
        let version = head[3]; var d = try read(h, at: at+10, count: size)
        if version < 4 && head[5] & 0x80 != 0 { d = deunsync(d) }
        if version == 2 && head[5] & 0x40 != 0 { return nil } // compressed tag
        var i = 0; var other: Data?
        if version >= 3 && head[5] & 0x40 != 0 {
            guard d.count >= 4 else { return nil }
            guard let n = version == 4 ? sync(d.prefix(4)) : Int(big(d.prefix(4))) else { return nil }
            i = version == 4 ? n : n+4; guard i >= 4, i <= d.count else { return nil }
        }
        for _ in 0..<8192 {
            let header = version == 2 ? 6 : 10
            guard i+header <= d.count, d[i] != 0 else { break }
            let nameLength = version == 2 ? 3 : 4
            let name = String(decoding: d[i..<i+nameLength], as: UTF8.self)
            let n: Int
            if version == 4 { guard let value = sync(d[i+4..<i+8]) else { break }; n = value }
            else { n = Int(big(d[i+nameLength..<i+header-(version == 3 ? 2 : 0)])) }
            let start = i+header; guard n > 0, n <= d.count-start else { break }
            let flags: UInt8 = version == 2 ? 0 : d[i+9]; i = start+n
            guard name == "APIC" || name == "PIC" else { continue }
            if version == 3 && flags & 0xc0 != 0 { continue }
            if version == 4 && flags & 0x4d != 0 { continue } // group/compression/encryption/data-length
            var body = Data(d[start..<start+n])
            if version == 4 && (flags & 2 != 0 || head[5] & 0x80 != 0) { body = deunsync(body) }
            if version == 3 && flags & 0x20 != 0 { body = Data(body.dropFirst()) }
            guard body.count >= 5 else { continue }
            let encoding = body[0]; var p: Int
            if name == "PIC" { p = 4 }
            else {
                guard let zero = body.dropFirst().firstIndex(of: 0) else { continue }
                if String(decoding: body[1..<zero], as: UTF8.self) == "-->" { continue }
                p = zero+1
            }
            guard p < body.count else { continue }; let type = body[p]; p += 1
            if encoding == 1 || encoding == 2 {
                while p+1 < body.count && !(body[p] == 0 && body[p+1] == 0) { p += 2 }; p += 2
            } else if encoding == 0 || encoding == 3 {
                while p < body.count && body[p] != 0 { p += 1 }; p += 1
            } else { continue }
            guard p < body.count else { continue }
            let picture = Data(body[p...]); guard thumbnail(picture) != nil else { continue }
            if type == 3 { return picture }; if other == nil { other = picture }
        }
        return other
    }
    private static func mp4(_ h: FileHandle, start: UInt64, end: UInt64, depth: Int, inCover: Bool, budget: inout Int) throws -> Data? {
        guard depth <= 8 else { return nil }; var at = start
        while at+8 <= end && budget > 0 {
            budget -= 1; let header = try read(h, at: at, count: 8)
            var n = big(header.prefix(4)); let type = String(decoding: header.suffix(4), as: UTF8.self); var skip: UInt64 = 8
            if n == 1 { guard at+16 <= end else { break }; n = big(try read(h, at: at+8, count: 8)); skip = 16 }
            else if n == 0 { n = end-at }
            guard n >= skip, n <= end-at else { break }
            if type == "data", inCover, n >= skip+8, n-skip-8 <= UInt64(maximumBytes) {
                let picture = try read(h, at: at+skip+8, count: Int(n-skip-8))
                if thumbnail(picture) != nil { return picture }
            }
            if ["moov","udta","meta","ilst","covr"].contains(type) {
                let begin = at+skip+(type == "meta" ? 4 : 0)
                if begin <= at+n, let picture = try mp4(h, start: begin, end: at+n, depth: depth+1, inCover: type == "covr", budget: &budget) { return picture }
            }
            at += n
        }
        return nil
    }
    public static func thumbnail(_ data: Data, pixels: Int = 768) -> Data? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache:false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(out,UTType.png.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(target,image,nil); guard CGImageDestinationFinalize(target) else { return nil }
        return out as Data
    }
}

/// Serialized image work and bounded thumbnail cache, exclusively inside application data.
public actor ArtworkRepository {
    private let folder: URL
    private let memory = NSCache<NSString,NSData>()
    private var generation = 0
    public init(cacheDirectory: URL) {
        folder = cacheDirectory
        memory.totalCostLimit = 32 * 1024 * 1024; memory.countLimit = 160
    }
    public func invalidate(musicRoots: [URL]) {
        generation += 1; memory.removeAllObjects()
        let path = folder.resolvingSymlinksInPath().path
        guard !musicRoots.contains(where: {
            let root = $0.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root+"/")
        }), let files = try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) else { return }
        for file in files where file.pathExtension == "png" && file.deletingPathExtension().lastPathComponent.range(of:#"^[0-9a-f]{64}$"#,options:.regularExpression) != nil {
            try? FileManager.default.removeItem(at:file)
        }
    }
    public static func folderCandidates(for audio: URL, root: URL) -> [URL] {
        let directory = audio.deletingLastPathComponent(); var dirs = [directory]
        let label = directory.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
        if label.range(of: #"^(cd|disc|disk)\d+$"#,options:.regularExpression) != nil { dirs.append(directory.deletingLastPathComponent()) }
        let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [URL] = []
        for dir in dirs {
            let directoryPath = dir.resolvingSymlinksInPath().path
            guard directoryPath == boundary || directoryPath.hasPrefix(boundary+"/") else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.isRegularFileKey],options:.skipsHiddenFiles) else { continue }
            let images = entries.filter { u in
                let path = u.resolvingSymlinksInPath().path
                return ["jpg","jpeg","png","webp"].contains(u.pathExtension.lowercased()) && (path == boundary || path.hasPrefix(boundary+"/")) && (try? u.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            func rank(_ u: URL) -> Int {
                let name = u.deletingPathExtension().lastPathComponent.lowercased()
                if let i = ["cover","folder","front","album","artwork"].firstIndex(of:name) { return i }
                if name.contains("front") || name.contains("cover") { return 10 }
                return 100
            }
            result += images.filter { rank($0) < 100 }.sorted { rank($0) == rank($1) ? $0.lastPathComponent < $1.lastPathComponent : rank($0) < rank($1) }
            if images.count == 1, result.last != images[0], !["back","rear","disc","booklet"].contains(images[0].deletingPathExtension().lastPathComponent.lowercased()) { result += images }
        }
        return result
    }
    public func artwork(sources: [URL], root: URL) async -> ArtworkResult? {
        let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path
        let sources = Array(sources.filter { $0.resolvingSymlinksInPath().path.hasPrefix(boundary+"/") }.prefix(256))
        guard !sources.isEmpty else { return nil }
        let requestGeneration = generation
        var candidates: [URL] = []
        var directories: Set<URL> = []
        for source in sources where directories.insert(source.deletingLastPathComponent()).inserted {
            for candidate in Self.folderCandidates(for: source, root: root) where !candidates.contains(candidate) { candidates.append(candidate) }
        }
        func signature(_ url: URL) -> String {
            let v = try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            return url.path+"|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }
        let key = SHA256.hash(data:Data((["art-v1"] + (sources+candidates).map(signature)).joined(separator:"\n").utf8)).map { String(format:"%02x",$0) }.joined()
        if let bytes = memory.object(forKey:key as NSString) { return .init(data:bytes as Data,source:"本机封面缓存") }
        let cached = folder.appendingPathComponent(key+".png")
        if let bytes = try? Data(contentsOf:cached), bytes.count <= EmbeddedArtwork.maximumBytes, EmbeddedArtwork.thumbnail(bytes) != nil {
            memory.setObject(bytes as NSData,forKey:key as NSString,cost:bytes.count); return .init(data:bytes,source:"本机封面缓存")
        }
        func save(_ bytes: Data, source: String) -> ArtworkResult? {
            guard requestGeneration == generation, !Task.isCancelled else { return nil }
            memory.setObject(bytes as NSData,forKey:key as NSString,cost:bytes.count)
            if !folder.resolvingSymlinksInPath().path.hasPrefix(boundary+"/"), folder.resolvingSymlinksInPath().path != boundary,
               (try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)) != nil {
                try? bytes.write(to:cached,options:.atomic)
                // Trim only files created by this cache, never files in the music directory.
                if let all = try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.contentModificationDateKey]), all.count > 800 {
                    let own = all.filter { $0.pathExtension == "png" && $0.deletingPathExtension().lastPathComponent.count == 64 }
                    for old in own.sorted(by:{ ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }).prefix(max(0,own.count-700)) { try? FileManager.default.removeItem(at:old) }
                }
            }
            return .init(data:bytes,source:source)
        }
        for url in sources {
            if Task.isCancelled { return nil }
            if let bytes = try? EmbeddedArtwork.read(url), let thumbnail = EmbeddedArtwork.thumbnail(bytes) { return save(thumbnail,source:"音频内嵌封面") }
        }
        // Apple metadata is a fallback for containers not covered by our native readers.
        for url in sources.prefix(16) where !["flac","iso"].contains(url.pathExtension.lowercased()) {
            if Task.isCancelled { return nil }
            if let items = try? await AVURLAsset(url:url).load(.commonMetadata) {
                for item in items where item.commonKey == .commonKeyArtwork {
                    if let bytes = try? await item.load(.dataValue), let thumbnail = EmbeddedArtwork.thumbnail(bytes) { return save(thumbnail,source:"音频内嵌封面") }
                }
            }
        }
        for url in candidates {
            if Task.isCancelled { return nil }
            guard let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= EmbeddedArtwork.maximumBytes else { continue }
            if let bytes = try? Data(contentsOf:url), let thumbnail = EmbeddedArtwork.thumbnail(bytes) { return save(thumbnail,source:"文件夹封面 · "+url.lastPathComponent) }
        }
        return nil
    }
}
