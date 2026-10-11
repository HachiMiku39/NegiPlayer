import Foundation
import CryptoKit

/// Digest only container payload regions. Metadata-only changes do not change lyric binding.
/// Unsupported/corrupt variants fail explicitly; no whole-file hash is substituted.
public enum AudioIdentity {
    private static func error(_ message: String) -> NSError { NSError(domain: "AudioIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    public static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let length = try file.seekToEnd(); try file.seek(toOffset: 0)
        let head = try file.read(upToCount: 32) ?? Data()
        func read(_ offset: UInt64, _ size: Int) throws -> Data { try file.seek(toOffset: offset); let d = try file.read(upToCount: size) ?? Data(); guard d.count == size else { throw error("载荷头不完整") }; return d }
        func integer(_ data: Data, little: Bool = false) -> UInt64 { (little ? Array(data.reversed()) : Array(data)).reduce(0) { ($0 << 8) | UInt64($1) } }
        var regions: [(UInt64, UInt64)] = []
        if head.prefix(4) == Data("RIFF".utf8), head.count >= 12, head[8..<12] == Data("WAVE".utf8) {
            var at: UInt64 = 12
            while at+8 <= length {
                let chunk = try read(at, 8); let size = integer(chunk.suffix(4), little: true)
                guard size <= length-at-8 else { throw error("RIFF chunk 越界") }
                if chunk.prefix(4) == Data("data".utf8) { regions.append((at+8, size)) }
                at += 8+size+size%2
            }
        } else if head.prefix(4) == Data("FORM".utf8), head.count >= 12,
                  head[8..<12] == Data("AIFF".utf8) || head[8..<12] == Data("AIFC".utf8) {
            var at: UInt64 = 12
            while at+8 <= length {
                let chunk = try read(at, 8); let size = integer(chunk.suffix(4))
                guard size <= length-at-8 else { throw error("AIFF chunk 越界") }
                if chunk.prefix(4) == Data("SSND".utf8) {
                    guard size >= 8 else { throw error("AIFF SSND 头不完整") }
                    let offset = integer(try read(at+8,4))
                    guard offset <= size-8 else { throw error("AIFF SSND offset 越界") }
                    regions.append((at+16+offset,size-8-offset))
                }
                at += 8+size+size%2
            }
        } else if head.prefix(4) == Data("fLaC".utf8) {
            var at: UInt64 = 4
            while true {
                let block = try read(at, 4); let size = integer(block.suffix(3)); guard size <= length-at-4 else { throw error("FLAC 元数据越界") }
                at += size+4; if block[0] & 0x80 != 0 { break }
            }
            regions.append((at, length-at))
        } else if head.prefix(4) == Data("DSD ".utf8) {
            // DSF fmt chunk is followed by a data chunk. The later ID3 pointer is excluded.
            let fmtHeader = try read(28, 12); guard fmtHeader.prefix(4) == Data("fmt ".utf8) else { throw error("DSF fmt 缺失") }
            let fmtSize = integer(fmtHeader.suffix(8), little: true); guard fmtSize >= 12, fmtSize <= length-28 else { throw error("DSF fmt 长度无效") }
            let at = 28+fmtSize; let data = try read(at, 12); let size = integer(data.suffix(8), little: true)
            guard data.prefix(4) == Data("data".utf8), size >= 12, size <= length-at else { throw error("DSF data 长度无效") }
            regions.append((at+12,size-12))
        } else if head.prefix(4) == Data("FRM8".utf8) {
            var at: UInt64 = 16
            while at+12 <= length {
                let chunk = try read(at, 12); let size = integer(chunk.suffix(8)); guard size <= length-at-12 else { throw error("DFF chunk 越界") }
                if chunk.prefix(4) == Data("DSD ".utf8) || chunk.prefix(4) == Data("DST ".utf8) { regions.append((at+12,size)) }
                at += 12+size+size%2
            }
        } else if head.count >= 12 && head[4..<8] == Data("ftyp".utf8) {
            var at: UInt64 = 0
            while at+8 <= length {
                let box = try read(at,8); var size = integer(box.prefix(4)); var header: UInt64 = 8
                if size == 1 { size = integer(try read(at+8,8)); header = 16 }
                if size == 0 { size = length-at }
                guard size >= header, size <= length-at else { throw error("MP4 atom 越界") }
                if box.suffix(4) == Data("mdat".utf8) { regions.append((at+header,size-header)) }
                at += size
            }
        } else if head.prefix(3) == Data("ID3".utf8) || (head.count >= 2 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0) {
            var begin: UInt64 = 0; var end = length
            if head.prefix(3) == Data("ID3".utf8) {
                guard head.count >= 10, head[6..<10].allSatisfy({ $0 < 128 }) else { throw error("ID3 大小无效") }
                let tagSize = head[6..<10].reduce(UInt64(0)) { ($0 << 7) | UInt64($1) }
                begin = 10+tagSize+(head[3] == 4 && head[5] & 0x10 != 0 ? 10 : 0)
            }
            if length >= 128, try read(length-128,3) == Data("TAG".utf8) { end -= 128 }
            if end >= 32 {
                let footer = try read(end-32,32)
                if footer.prefix(8) == Data("APETAGEX".utf8) {
                    let size = integer(footer[12..<16], little: true)
                    guard size >= 32, size <= end else { throw error("APE 标签长度无效") }; end -= size
                }
            }
            guard begin <= end else { throw error("MP3 标签越界") }; regions.append((begin,end-begin))
        } else { throw error("该容器的标签独立载荷摘要尚未覆盖") }
        guard !regions.isEmpty, regions.contains(where: { $0.1 > 0 }) else { throw error("没有发现有效音频载荷") }
        var hash = SHA256()
        for (offset, size) in regions {
            try file.seek(toOffset: offset); var left = size
            while left > 0 {
                try Task.checkCancellation()
                let block = try file.read(upToCount: Int(min(1_048_576,left))) ?? Data()
                guard !block.isEmpty else { throw error("载荷读取中断") }; hash.update(data: block); left -= UInt64(block.count)
            }
        }
        return "payload-sha256:"+hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
