import Foundation
import CryptoKit

public struct EnrichmentError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct SMFMFSummary: Codable, Equatable, Sendable {
    public struct Chunk: Codable, Equatable, Sendable { public let name: String; public let bytes: Int }
    public let bpm: Double?
    public let chunks: [Chunk]
    public let bytes: Int
    public static func parse(_ data: Data) throws -> SMFMFSummary {
        guard !data.isEmpty, data.count <= 16_777_216 else { throw EnrichmentError("SensMe 数据长度无效") }
        var at = 0, chunks: [Chunk] = [], bpm: Double?
        while at < data.count {
            guard data.count - at >= 20, data[at+4..<at+8] == Data("STAE".utf8), data[at+8..<at+12] == Data("MMLW".utf8) else { throw EnrichmentError("SensMe 分块头无效") }
            let size = data[at+16..<at+20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(size) <= data.count - at - 20 else { throw EnrichmentError("SensMe 分块越界") }
            let name = String(decoding: data[at..<at+4], as: UTF8.self)
            if name == "GBPM", size == 4 {
                let bits = data[at+20..<at+24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let value = Double(Float(bitPattern: bits))
                if value.isFinite, value > 0, value < 1000 { bpm = value }
            }
            chunks.append(.init(name: name, bytes: Int(size))); at += 20 + Int(size)
        }
        // Sony returns valid STMM analysis without GBPM when tempo cannot be established.
        guard chunks.contains(where: { $0.name == "STMM" }) else { throw EnrichmentError("SensMe 结果缺少分析分块") }
        return .init(bpm: bpm, chunks: chunks, bytes: data.count)
    }
}

public enum SourceDigest {
    public static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct CachedSensMe: Codable, Sendable {
    public let sourceSHA256: String
    public let engineVersion: String
    public let summary: SMFMFSummary
    public let blob: Data
    public let blobSHA256: String?
    public let analyzedAt: Date
    public init(sourceSHA256: String, engineVersion: String, blob: Data) throws {
        self.sourceSHA256 = sourceSHA256; self.engineVersion = engineVersion
        self.summary = try SMFMFSummary.parse(blob); self.blob = blob; self.analyzedAt = Date()
        self.blobSHA256 = Self.digest(blob)
    }
    public var hasValidBlobChecksum: Bool {
        guard let blobSHA256, Self.digest(blob) == blobSHA256 else { return false }
        return (try? SMFMFSummary.parse(blob)) == summary
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
