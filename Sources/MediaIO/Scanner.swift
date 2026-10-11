import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit
import LibraryDomain

public enum MediaProbe {
    public static let extensions: Set<String> = ["mp3", "wav", "flac", "m4a", "dsf", "dff", "aif", "aiff", "aac", "iso"]
    public static func detect(_ url: URL) throws -> (codec: String, rate: Double, channels: Int, duration: Double) {
        if url.pathExtension.lowercased() == "iso" { return (try DiscImageProbe.inspect(url).kind,0,0,0) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let header = try handle.read(upToCount: 128) ?? Data()
        if header.starts(with: Data("DSD ".utf8)) {
            guard header.count >= 92, String(decoding: header[28..<32], as: UTF8.self) == "fmt " else { throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "DSF fmt 头不完整"]) }
            func u32(_ n: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(header[n+$1]) << ($1*8) } }
            func u64(_ n: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(header[n+$1]) << ($1*8) } }
            let rate = Double(u32(56)); let ch = Int(u32(52)); let samples = u64(64)
            guard rate > 0, ch > 0 else { throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效 DSF 采样参数"]) }
            return ("DSD (DSF)", rate, ch, Double(samples)/rate)
        }
        if header.starts(with: Data("FRM8".utf8)) {
            // Parse bounded IFF chunks; never infer DST from file extension.
            guard header.count >= 16, String(decoding: header[12..<16], as: UTF8.self) == "DSD " else { throw NSError(domain: "Probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "不支持的 DFF form 类型"]) }
            let length = try handle.seekToEnd(); try handle.seek(toOffset: 16)
            var codec = "DSD (DFF)"; var rate: Double = 0; var channels = 0; var audioBytes: UInt64 = 0
            func be64(_ d: Data) -> UInt64 { d.reduce(0) { ($0 << 8) | UInt64($1) } }
            while try handle.offset() + 12 <= length {
                let chunk = try handle.read(upToCount: 12) ?? Data(); guard chunk.count == 12 else { break }
                let id = String(decoding: chunk.prefix(4), as: UTF8.self); let size = be64(chunk.suffix(8))
                let begin = try handle.offset(); guard size <= length-begin else { throw NSError(domain: "Probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "DFF chunk 长度损坏"]) }
                if id == "PROP", size < 1_000_000 {
                    let data = try handle.read(upToCount: Int(size)) ?? Data(); var at = 4
                    while at + 12 <= data.count {
                        let name = String(decoding: data[at..<at+4], as: UTF8.self); let n = be64(data[at+4..<at+12]); let start = at+12
                        guard n <= UInt64(data.count-start) else { break }
                        if name == "FS  ", n >= 4 { rate = Double(be64(data[start..<start+4])) }
                        if name == "CHNL", n >= 2 { channels = Int(be64(data[start..<start+2])) }
                        if name == "CMPR", n >= 4, String(decoding: data[start..<start+4], as: UTF8.self) == "DST " { codec = "DST" }
                        at = start + Int(n) + Int(n % 2)
                    }
                }
                if id == "DSD " { audioBytes = size }
                if id == "DST " { codec = "DST" }
                try handle.seek(toOffset: begin + size + size % 2)
            }
            return (codec, rate, channels, rate > 0 && channels > 0 ? Double(audioBytes)*8/rate/Double(channels) : 0)
        }
        let audio = try AVAudioFile(forReading: url)
        let f = audio.fileFormat; let asbd = f.streamDescription.pointee
        let codec: String
        switch asbd.mFormatID {
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatMPEG4AAC: codec = "AAC"
        case kAudioFormatAppleLossless: codec = "ALAC"
        case kAudioFormatFLAC: codec = "FLAC"
        case kAudioFormatLinearPCM: codec = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "PCM Float" : "PCM \(asbd.mBitsPerChannel)-bit"
        default: codec = "编码 0x" + String(asbd.mFormatID, radix: 16)
        }
        return (codec, f.sampleRate, Int(f.channelCount), Double(audio.length)/audio.processingFormat.sampleRate)
    }
    public static func metadata(_ url: URL) async -> [String: [String]] {
        if url.pathExtension.lowercased() == "flac", let tags = try? FLACMetadata.read(url) { return tags }
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return [:] }
        var tags: [String: [String]] = [:]
        for item in items {
            guard let key = item.commonKey?.rawValue, let value = try? await item.load(.stringValue) else { continue }
            tags[key, default: []].append(value)
        }
        // Album artist is a separate relationship; do not substitute the creator/composer field.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let raw = try? await asset.loadMetadata(for: format) else { continue }
                for item in raw {
                    if item.identifier == .iTunesMetadataAlbumArtist || item.identifier == .id3MetadataBand,
                       let value = try? await item.load(.stringValue) { tags["albumArtist",default: []].append(value) }
                    if item.identifier == .id3MetadataTrackNumber, let value = try? await item.load(.stringValue) { tags["trackNumber",default: []].append(value) }
                    if item.identifier == .id3MetadataPartOfASet, let value = try? await item.load(.stringValue) { tags["discNumber",default: []].append(value) }
                }
            }
        }
        return tags
    }
}

public enum LibraryScanner {
    private static let metadataVersion = 2
    public static func scan(root: LibraryRoot, url: URL, previous: [MediaFile], progress: @Sendable (Int, String) async -> Void) async throws -> [MediaFile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw NSError(domain: "Scanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "目录离线或无法访问"]) }
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.relativePath, $0) })
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw NSError(domain: "Scanner", code: 2) }
        var result: [MediaFile] = []
        // This function must run in a detached/background task. Metadata awaits do not move traversal onto UI.
        while let file = e.nextObject() as? URL {
            try Task.checkCancellation()
            guard MediaProbe.extensions.contains(file.pathExtension.lowercased()) else { continue }
            let resource = try file.resourceValues(forKeys: Set(keys))
            guard resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
            let relative = String(file.path.dropFirst(url.path.count + (url.path.hasSuffix("/") ? 0 : 1)))
            let size = Int64(resource.fileSize ?? 0); let modified = resource.contentModificationDate?.timeIntervalSince1970 ?? 0
            if var cached = old[relative], cached.size == size, cached.modified == modified, cached.metadataVersion == metadataVersion {
                cached.available = true; result.append(cached)
            } else {
                var f = MediaFile(id: old[relative]?.id ?? UUID().uuidString, rootID: root.id, relativePath: relative,
                                  title: file.deletingPathExtension().lastPathComponent, size: size, modified: modified)
                f.metadataVersion = metadataVersion
                do {
                    let p = try MediaProbe.detect(file); f.codec = p.codec; f.sampleRate = p.rate; f.channels = p.channels; f.duration = p.duration
                    f.tags = f.isDiscImage ? [:] : await MediaProbe.metadata(file)
                    f.title = f.tags["title"]?.first ?? f.title
                    f.artists = f.tags["artist"] ?? []
                    f.album = f.tags["albumName"]?.first ?? ""
                    f.albumArtist = f.tags["albumArtist"]?.first ?? ""
                    f.trackNumber = Int(f.tags["trackNumber"]?.first?.components(separatedBy: "/").first ?? "") ?? 0
                    f.discNumber = Int(f.tags["discNumber"]?.first?.components(separatedBy: "/").first ?? "") ?? 1
                    // Import is a metadata scan. Full payload hashes are computed only for a selected
                    // lyric binding, so a large reference library is never copied or read end-to-end.
                    if f.isDSD { f.issue = f.codec == "DST" ? "DST 原始 DSD 解码尚未接通" : "DSD／DoP 输出尚未接通" }
                    if f.isDiscImage { f.issue = try DiscImageProbe.inspect(file).detail }
                } catch { f.codec = "未识别"; f.issue = error.localizedDescription }
                // Folder and root separate editions conservatively; do not merge solely by title/artist.
                let identity = root.id + "|" + file.deletingLastPathComponent().path + "|" + f.album + "|" + f.albumArtist
                f.releaseKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                let refreshed = try file.resourceValues(forKeys: Set(keys))
                guard refreshed.fileSize == resource.fileSize, refreshed.contentModificationDate == resource.contentModificationDate else {
                    throw NSError(domain: "Scanner", code: 3, userInfo: [NSLocalizedDescriptionKey: "文件在扫描期间改变，请重试：\(relative)"])
                }
                result.append(f)
            }
            if result.count % 10 == 0 { await progress(result.count, relative) }
        }
        if let enumerationError { throw enumerationError }
        await progress(result.count, "扫描完成")
        return result
    }
}
