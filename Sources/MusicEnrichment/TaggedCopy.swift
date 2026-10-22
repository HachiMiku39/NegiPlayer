import Foundation
import LibraryDomain
import MediaIO

public struct TransferEnrichment: Sendable {
    public let sourceSHA256: String
    public let sensme: Data?
    public let metadata: MetadataPatch?
    public let artwork: EnrichmentArtwork?
    public init(sourceSHA256: String, sensme: Data? = nil, metadata: MetadataPatch? = nil, artwork: EnrichmentArtwork? = nil) { self.sourceSHA256 = sourceSHA256; self.sensme = sensme; self.metadata = metadata; self.artwork = artwork }
}

/// Metadata is committed only to a new copy. The audio payload must remain identical.
public enum TaggedMusicCopy {
    public static func write(source: URL, destination: URL, enrichment: TransferEnrichment) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path), source.standardizedFileURL != destination.standardizedFileURL else { throw EnrichmentError("补全副本目标必须是新文件") }
        guard try SourceDigest.sha256(source) == enrichment.sourceSHA256 else { throw EnrichmentError("源文件已改变，请重新分析或查询后传输") }
        if let blob = enrichment.sensme { _ = try SMFMFSummary.parse(blob) }
        let before = try AudioIdentity.digest(source)
        let ext = source.pathExtension.lowercased()
        guard ["mp3", "flac"].contains(ext) else { throw EnrichmentError("目前仅 MP3 和 FLAC 副本可携带 SensMe 与补全标签") }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw EnrichmentError("无法创建补全副本") }
        let output = try FileHandle(forWritingTo: destination)
        do {
            if ext == "flac" { try flac(input, output, enrichment) } else { try mp3(input, output, enrichment) }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
            try output.synchronize(); try output.close()
            guard try AudioIdentity.digest(destination) == before, try SourceDigest.sha256(source) == enrichment.sourceSHA256 else { throw EnrichmentError("标签副本音频载荷校验失败，已停止传输") }
        } catch { try? output.close(); try? fm.removeItem(at: destination); throw error }
    }
    private static func exact(_ file: FileHandle, _ count: Int) throws -> Data {
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw EnrichmentError("音频标签长度无效") }; return data
    }
    private static func be(_ value: Int, _ count: Int = 4) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func le(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func number(_ data: Data) -> Int { data.reduce(0) { ($0 << 8) | Int($1) } }
    private static func synchsafe(_ value: Int) -> Data { Data((0..<4).reversed().map { UInt8((value >> ($0 * 7)) & 127) }) }
    private static func syncNumber(_ data: Data) throws -> Int {
        guard data.count == 4, data.allSatisfy({ $0 < 128 }) else { throw EnrichmentError("ID3 同步安全长度无效") }
        return data.reduce(0) { ($0 << 7) | Int($1) }
    }
    private static func flac(_ input: FileHandle, _ output: FileHandle, _ enrichment: TransferEnrichment) throws {
        guard try exact(input, 4) == Data("fLaC".utf8) else { throw EnrichmentError("无效 FLAC 文件") }
        var blocks: [(UInt8, Data)] = [], last = false, total = 0, commentsWritten = false
        while !last {
            let h = try exact(input, 4), kind = h[0] & 127, size = number(Data(h.suffix(3)))
            total += size; guard total <= 64 * 1024 * 1024 else { throw EnrichmentError("FLAC 标签过大") }
            var data = try exact(input, size); last = h[0] & 128 != 0
            if kind == 2, data.prefix(4) == Data("SMFM".utf8), enrichment.sensme != nil { continue }
            if kind == 6, enrichment.artwork != nil {
                guard data.count >= 4 else { throw EnrichmentError("FLAC 封面块损坏") }
                if number(Data(data.prefix(4))) == 3 { continue }
            }
            if kind == 4, let patch = enrichment.metadata { data = try vorbis(data, fields: patch.vorbisFields); commentsWritten = true }
            blocks.append((kind, data))
        }
        guard blocks.first?.0 == 0, blocks.first?.1.count == 34 else { throw EnrichmentError("FLAC 缺少有效 STREAMINFO") }
        if let patch = enrichment.metadata, !commentsWritten { blocks.append((4, try vorbis(le(0)+le(0), fields: patch.vorbisFields))) }
        if let blob = enrichment.sensme { blocks.append((2, Data("SMFM".utf8) + blob)) }
        if let art = enrichment.artwork {
            let mime = Data(art.mimeType.utf8)
            let picture = be(3) + be(mime.count) + mime + be(0) + be(art.width) + be(art.height) + be(24) + be(0) + be(art.data.count) + art.data
            blocks.append((6, picture))
        }
        try output.write(contentsOf: Data("fLaC".utf8))
        for (index, block) in blocks.enumerated() {
            guard block.1.count <= 0xFFFFFF else { throw EnrichmentError("FLAC 元数据块过大") }
            try output.write(contentsOf: Data([block.0 | (index == blocks.count-1 ? 128 : 0)]) + be(block.1.count, 3) + block.1)
        }
    }
    private static func vorbis(_ data: Data, fields: [String: String]) throws -> Data {
        var at = 0
        func take() throws -> Data {
            guard at + 4 <= data.count else { throw EnrichmentError("Vorbis Comment 长度无效") }
            let n = data[at..<at+4].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }; at += 4
            guard n <= data.count-at else { throw EnrichmentError("Vorbis Comment 越界") }
            let value = Data(data[at..<at+n]); at += n; return value
        }
        let vendor = try take()
        guard at + 4 <= data.count else { throw EnrichmentError("Vorbis Comment 缺少数量") }
        let count = data[at..<at+4].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }; at += 4
        guard count <= 100_000 else { throw EnrichmentError("Vorbis Comment 数量过大") }
        var comments: [Data] = []
        for _ in 0..<count {
            let raw = try take(), key = String(decoding: raw.prefix(while: { $0 != 61 }), as: UTF8.self).uppercased()
            if fields[key] == nil { comments.append(raw) }
        }
        guard at == data.count else { throw EnrichmentError("Vorbis Comment 含未知尾部") }
        comments += fields.keys.sorted().map { Data(($0 + "=" + fields[$0]!).utf8) }
        return le(vendor.count) + vendor + le(comments.count) + comments.reduce(Data()) { $0 + le($1.count) + $1 }
    }
    private static func mp3(_ input: FileHandle, _ output: FileHandle, _ enrichment: TransferEnrichment) throws {
        let header = try input.read(upToCount: 10) ?? Data()
        var version: UInt8 = 4, frames: [(String, Data)] = []
        if header.prefix(3) == Data("ID3".utf8) {
            guard header.count == 10, [3, 4].contains(header[3]), header[5] == 0 else { throw EnrichmentError("此 MP3 的 ID3 扩展／非同步标志暂不支持写入，原文件未改动") }
            version = header[3]; let size = try syncNumber(Data(header[6..<10]))
            guard size <= 32 * 1024 * 1024 else { throw EnrichmentError("MP3 标签过大") }
            let tag = try exact(input, size); var at = 0
            while at < tag.count, tag[at] != 0 {
                guard at + 10 <= tag.count else { throw EnrichmentError("ID3 帧头不完整") }
                let idData = Data(tag[at..<at+4])
                guard idData.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw EnrichmentError("ID3 帧标识无效") }
                let id = String(decoding: idData, as: UTF8.self)
                let size = version == 4 ? try syncNumber(Data(tag[at+4..<at+8])) : number(Data(tag[at+4..<at+8]))
                guard size <= tag.count-at-10 else { throw EnrichmentError("ID3 帧越界") }
                let payload = Data(tag[at+10..<at+10+size])
                let oldSensMe = id == "GEOB" && String(decoding: payload.prefix(32), as: UTF8.self).lowercased().contains("application/smfmf")
                if !(oldSensMe && enrichment.sensme != nil) { frames.append((id, Data(tag[at..<at+10+size]))) }
                at += 10 + size
            }
            guard tag[at...].allSatisfy({ $0 == 0 }) else { throw EnrichmentError("ID3 填充数据无效") }
        } else { try input.seek(toOffset: 0) }
        func frame(_ id: String, _ payload: Data) -> Data { Data(id.utf8) + (version == 4 ? synchsafe(payload.count) : be(payload.count)) + Data([0, 0]) + payload }
        func textPayload(_ text: String) -> Data {
            version == 4 ? Data([3]) + Data(text.utf8) : Data([1, 255, 254]) + (text.data(using: .utf16LittleEndian) ?? Data())
        }
        func oldText(_ id: String) -> String {
            guard let value = frames.first(where: { $0.0 == id })?.1, value.count > 10, value[9] == 0 else { return "" }
            let body = Data(value.dropFirst(10)), encoding: String.Encoding
            switch body[0] { case 0: encoding = .isoLatin1; case 1: encoding = .utf16; case 2: encoding = .utf16BigEndian; case 3: encoding = .utf8; default: return "" }
            return (String(data: body.dropFirst(), encoding: encoding) ?? "").trimmingCharacters(in: .init(charactersIn: "\0"))
        }
        if let patch = enrichment.metadata {
            var fields = ["TIT2": patch.title, "TPE1": patch.artist, "TALB": patch.album, version == 4 ? "TDRC" : "TYER": patch.year, "TCON": patch.genre]
            for (field, id) in [(MetadataField.albumArtist,"TPE2"),(.label,"TPUB"),(.composer,"TCOM"),(.lyricist,"TEXT"),(.conductor,"TPE3"),(.copyright,"TCOP"),(.isrc,"TSRC"),(.language,"TLAN"),(.compilation,"TCMP"),(.originalYear,version == 4 ? "TDOR" : "TORY")] { fields[id] = patch[field] }
            for (field, total, id) in [(MetadataField.track,MetadataField.trackTotal,"TRCK"),(.disc,.discTotal,"TPOS")] {
                if !patch[field].isEmpty || !patch[total].isEmpty {
                    let old = oldText(id).components(separatedBy: "/")
                    let supplied = patch[field].components(separatedBy: "/")
                    let number = patch[field].isEmpty ? old.first ?? "" : supplied[0]
                    let count = !patch[total].isEmpty ? patch[total] : (supplied.count > 1 ? supplied[1] : (old.count > 1 ? old[1] : ""))
                    fields[id] = number + (count.isEmpty ? "" : "/" + count)
                }
            }
            fields = fields.filter { !$0.value.isEmpty }
            frames.removeAll { fields[$0.0] != nil }
            for id in fields.keys.sorted() { frames.append((id, frame(id, textPayload(fields[id]!)))) }
            let custom: [MetadataField] = [.barcode, .catalogNumber, .artistOrigin, .artistEra, .artistType]
            for field in custom where !patch[field].isEmpty {
                frames.removeAll { item in
                    guard item.0 == "TXXX", item.1.count > 11, item.1[9] == 0 else { return false }
                    let payload = Data(item.1.dropFirst(10))
                    let encoding: String.Encoding = payload[0] == 1 ? .utf16 : (payload[0] == 2 ? .utf16BigEndian : (payload[0] == 3 ? .utf8 : .isoLatin1))
                    let description = String(data: payload.dropFirst(), encoding: encoding)?.components(separatedBy: "\0").first
                    return description?.uppercased() == field.rawValue
                }
                frames.append(("TXXX", frame("TXXX", textPayload(field.rawValue + "\0" + patch[field]))))
            }
        }
        if let art = enrichment.artwork {
            var kept: [(String,Data)] = []
            for item in frames {
                if item.0 == "APIC" {
                    guard item.1.count > 12, item.1[9] == 0 else { throw EnrichmentError("此 MP3 封面帧标志暂不支持替换") }
                    let body = Data(item.1.dropFirst(10))
                    guard let zero = body.dropFirst().firstIndex(of: 0), zero + 1 < body.count else { throw EnrichmentError("MP3 封面帧损坏") }
                    if body[zero + 1] == 3 { continue }
                }
                kept.append(item)
            }
            frames = kept
            let payload = Data([0]) + Data((art.mimeType + "\0").utf8) + Data([3, 0]) + art.data
            frames.append(("APIC", frame("APIC", payload)))
        }
        if let blob = enrichment.sensme {
            let payload = Data([0]) + Data("Application/SMFMF\0\0USR_SMFMF\0".utf8) + blob
            frames.append(("GEOB", frame("GEOB", payload)))
        }
        let body = frames.reduce(Data()) { $0 + $1.1 }
        guard body.count < 0x10000000 else { throw EnrichmentError("输出 ID3 标签过大") }
        try output.write(contentsOf: Data("ID3".utf8) + Data([version, 0, 0]) + synchsafe(body.count) + body)
    }
}
