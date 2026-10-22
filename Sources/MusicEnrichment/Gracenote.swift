import Foundation
import LibraryDomain

public struct GracenoteCandidate: Codable, Identifiable, Sendable {
    public let id: String
    public let metadata: MetadataPatch
    public let artwork: [GracenoteCoverAsset]?
    public let sdkData: String?
    public let fullResult: Bool?
    public var covers: [GracenoteCoverAsset] { artwork ?? [] }
    public init(id: String, metadata: MetadataPatch, artwork: [GracenoteCoverAsset]? = nil, sdkData: String? = nil, fullResult: Bool? = nil) {
        self.id = id; self.metadata = metadata; self.artwork = artwork; self.sdkData = sdkData; self.fullResult = fullResult
    }
}
public struct GracenoteResponse: Codable, Sendable {
    public let sdkVersion: String
    public let ready: Bool
    public let candidates: [GracenoteCandidate]
}
public enum GracenoteEngine {
    public static func query(title: String = "", artist: String = "", album: String = "", probe: Bool = false,
                             runtime: EnrichmentRuntime, credentials: URL, workingDirectory: URL, detail: GracenoteCandidate? = nil) throws -> GracenoteResponse {
        guard FileManager.default.fileExists(atPath: credentials.path) else { throw EnrichmentError("请先导入 Media Go 本机授权") }
        let fm = FileManager.default, job = workingDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: job, withIntermediateDirectories: true); defer { try? fm.removeItem(at: job) }
        let request = job.appendingPathComponent("request.json"), result = job.appendingPathComponent("result.json")
        let user = credentials.deletingLastPathComponent().appendingPathComponent("user.dat")
        var body: [String: String] = ["action": probe ? "probe" : "search", "title": title, "artist": artist, "album": album]
        if let detail, let serialized = detail.sdkData {
            body["action"] = "details"; body["sdkData"] = serialized; body["track"] = detail.metadata.track
        }
        try JSONSerialization.data(withJSONObject: body).write(to: request)
        let wp = EnrichmentRuntime.windowsPath
        defer { if fm.fileExists(atPath: user.path) { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: user.path) } }
        try runtime.run(helper: "gracenote_windows.py", arguments: ["--sdk-dir", wp(runtime.gracenoteDirectory), "--config", wp(credentials), "--user", wp(user), "--request", wp(request), "--out", wp(result)], job: job, timeout: 90)
        let data = try Data(contentsOf: result)
        guard data.count <= 4_194_304 else { throw EnrichmentError("Gracenote 返回数据过大") }
        return try JSONDecoder().decode(GracenoteResponse.self, from: data)
    }
}

public enum MediaGoCredentials {
    /// Only the exact user-supplied Media Go 3.2 build audited in this workspace is supported.
    /// Secrets are recovered locally, never embedded into application source or diagnostics.
    public static func importExecutable(_ url: URL, to destination: URL) throws {
        guard try SourceDigest.sha256(url) == "e6abbd21a861d2a5d96619b40f5a4c0435500280ac9ec1297eddc3e3f5f32ddc" else { throw EnrichmentError("此导入器仅支持已核对的 Media Go 3.2 Build 191 的 MediaGo.exe") }
        let data = try Data(contentsOf: url)
        func wide(_ offset: Int) throws -> String {
            var end = offset
            while end + 2 <= data.count, data[end..<end+2] != Data([0, 0]), end-offset < 16384 { end += 2 }
            guard end + 2 <= data.count, let text = String(data: data[offset..<end], encoding: .utf16LittleEndian) else { throw EnrichmentError("Media Go 授权字段无效") }
            return text
        }
        let license = try wide(0x145a740), tag = try wide(0x145a6f8), client = try wide(0x145a6e8)
        guard license.contains("-- BEGIN LICENSE"), license.contains("-- END LICENSE"), tag.count == 32, client.allSatisfy(\.isNumber) else { throw EnrichmentError("Media Go 授权校验失败") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let json = try JSONSerialization.data(withJSONObject: ["license": license, "client_id": client, "client_tag": tag, "client_version": "3.2"])
        try json.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
