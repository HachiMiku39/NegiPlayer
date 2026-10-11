import Foundation
import CryptoKit

public struct WAVValidationError: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}
public struct WAVChunk: Equatable {
    public var id: String
    public var offset: UInt64
    public var size: UInt32
}

/// M0 probe only: writes a separate validated WAV copy; never commits to the source file.
/// Limited to ASCII RIFF INFO in PCM/float WAVE. ID3 coexistence and RF64 are rejected.
public enum WAVCopyVerifier {
    private static func fail(_ message: String) -> WAVValidationError { .init(message: message) }
    private static func u32(_ d: Data) -> UInt32 { d.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset*8)) } }
    private static func le32(_ n: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0*8)) }) }
    public static func chunks(_ url: URL) throws -> [WAVChunk] {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        let header = try file.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8), UInt64(u32(header[4..<8]))+8 == size else { throw fail("仅支持长度一致的 RIFF WAVE；RF64／尾部附加数据尚未覆盖") }
        var result: [WAVChunk] = []
        while try file.offset() < size {
            let h = try file.read(upToCount: 8) ?? Data()
            guard h.count == 8 else { throw fail("WAV chunk 头不完整") }
            let n = u32(h.suffix(4)); let offset = try file.offset()
            guard UInt64(n)+UInt64(n%2) <= size-offset else { throw fail("WAV chunk 超出文件范围") }
            result.append(.init(id: String(decoding: h.prefix(4), as: UTF8.self), offset: offset, size: n))
            try file.seek(toOffset: offset+UInt64(n)+UInt64(n%2))
        }
        guard let fmt = result.first(where: { $0.id == "fmt " }), fmt.size >= 16, result.contains(where: { $0.id == "data" }) else { throw fail("WAV 缺少 fmt 或 data") }
        try file.seek(toOffset: fmt.offset); let tag = try file.read(upToCount: 2) ?? Data()
        guard tag == Data([1,0]) || tag == Data([3,0]) else { throw fail("此验证器只覆盖标准整数／浮点 PCM") }
        return result
    }
    public static func audioDigest(_ url: URL) throws -> String {
        let entries = try chunks(url).filter { $0.id == "data" }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        for entry in entries {
            try handle.seek(toOffset: entry.offset); var left = UInt64(entry.size)
            while left > 0 {
                let data = try handle.read(upToCount: Int(min(left, 1_048_576))) ?? Data()
                guard !data.isEmpty else { throw fail("音频载荷读取不完整") }
                hash.update(data: data); left -= UInt64(data.count)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func info(_ url: URL) throws -> [String: String] {
        let entries = try chunks(url); let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var result: [String: String] = [:]
        for c in entries where c.id == "LIST" {
            guard c.size < 8_000_000 else { throw fail("LIST 元数据超过验证器限额") }
            try file.seek(toOffset: c.offset); let data = try file.read(upToCount: Int(c.size)) ?? Data()
            guard data.prefix(4) == Data("INFO".utf8) else { continue }
            for item in try infoItems(data) { result[item.id] = String(decoding: item.payload.prefix(while: { $0 != 0 }), as: UTF8.self) }
        }
        return result
    }
    private static func infoItems(_ data: Data) throws -> [(id: String, payload: Data, raw: Data)] {
        var at = 4; var out: [(String, Data, Data)] = []
        while at < data.count {
            guard at+8 <= data.count else { throw fail("INFO 子项不完整") }
            let n = Int(u32(data[at+4..<at+8])); let end = at+8+n+n%2
            guard end <= data.count else { throw fail("INFO 子项长度无效") }
            out.append((String(decoding: data[at..<at+4], as: UTF8.self), Data(data[at+8..<at+8+n]), Data(data[at..<end])))
            at = end
        }
        return out
    }
    public static func writeValidatedCopy(source: URL, destination: URL, fields: [String: String]) throws -> String {
        guard source.standardizedFileURL != destination.standardizedFileURL, !FileManager.default.fileExists(atPath: destination.path) else { throw fail("必须选择不存在的新副本路径，不能覆盖源文件") }
        let allowed: Set<String> = ["INAM", "IART", "IPRD", "ICMT"]
        guard fields.keys.allSatisfy({ allowed.contains($0) }), fields.values.allSatisfy({ $0.utf8.count <= 10_000 && $0.unicodeScalars.allSatisfy { $0.value > 0 && $0.value < 128 } }) else { throw fail("M0 验证器仅覆盖 ASCII INFO 标题／艺人／专辑／注释") }
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let entries = try chunks(source)
        guard !entries.contains(where: { $0.id.lowercased() == "id3 " }) else { throw fail("包含 ID3 的 WAV 尚未定义同步策略，本次停止写入") }
        let before = try audioDigest(source)
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".lmp-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw fail("无法创建临时副本") }
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = try FileHandle(forWritingTo: temp); defer { try? output.close() }
        try output.write(contentsOf: Data("RIFF".utf8)+Data(repeating: 0, count: 4)+Data("WAVE".utf8))
        var infoWritten = false
        func rewrittenInfo(_ original: Data) throws -> Data {
            var body = Data("INFO".utf8)
            for item in try infoItems(original) where fields[item.id] == nil { body += item.raw }
            for key in fields.keys.sorted() {
                let text = Data(fields[key]!.utf8)+Data([0]); body += Data(key.utf8)+le32(UInt32(text.count))+text
                if text.count%2 != 0 { body.append(0) }
            }
            return Data("LIST".utf8)+le32(UInt32(body.count))+body
        }
        for entry in entries {
            try input.seek(toOffset: entry.offset)
            if entry.id == "LIST" {
                let tag = try input.read(upToCount: 4) ?? Data(); try input.seek(toOffset: entry.offset)
                if tag == Data("INFO".utf8) {
                    guard !infoWritten, entry.size < 8_000_000 else { throw fail("多个 INFO 或过大元数据尚未覆盖") }
                    let original = try input.read(upToCount: Int(entry.size)) ?? Data()
                    try output.write(contentsOf: rewrittenInfo(original)); infoWritten = true; continue
                }
            }
            try output.write(contentsOf: Data(entry.id.utf8)+le32(entry.size))
            var left = UInt64(entry.size)+UInt64(entry.size%2)
            while left > 0 {
                let block = try input.read(upToCount: Int(min(left,1_048_576))) ?? Data()
                guard !block.isEmpty else { throw fail("副本读取中断") }; try output.write(contentsOf: block); left -= UInt64(block.count)
            }
        }
        if !infoWritten { try output.write(contentsOf: rewrittenInfo(Data("INFO".utf8))) }
        let size = try output.offset(); guard size-8 <= UInt32.max else { throw fail("输出超过 RIFF 32 位长度") }
        try output.seek(toOffset: 4); try output.write(contentsOf: le32(UInt32(size-8))); try output.synchronize()
        let after = try audioDigest(temp); guard before == after else { throw fail("音频载荷摘要不同，停止提交副本") }
        let observed = try info(temp)
        guard fields.allSatisfy({ observed[$0.key] == $0.value }) else { throw fail("标签回读不一致") }
        let now = try FileManager.default.attributesOfItem(atPath: source.path)
        for key in [FileAttributeKey.size, .modificationDate, .systemFileNumber] {
            guard String(describing: now[key]) == String(describing: originalAttributes[key]) else { throw fail("源文件在副本处理期间改变，请重新读取") }
        }
        guard try audioDigest(source) == before else { throw fail("源音频在副本处理期间改变") }
        try FileManager.default.moveItem(at: temp, to: destination)
        return after
    }
}
