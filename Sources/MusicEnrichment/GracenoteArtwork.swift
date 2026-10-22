import Foundation
import ImageIO
import CryptoKit

public struct GracenoteCoverAsset: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let url: String
    public let size: String
    public let width: Int
    public let height: Int
    public let estimatedBytes: Int
    public var label: String { "\(width) × \(height)" }
}

public struct EnrichmentArtwork: Sendable, Equatable {
    public static let maximumBytes = 8 * 1024 * 1024
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
    public var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 33_554_432,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else {
            throw EnrichmentError("封面必须是有效 JPEG／PNG，且不超过 8 MiB 和 8192 像素")
        }
        self.data = data; self.mimeType = type == "public.jpeg" ? "image/jpeg" : "image/png"; self.width = width; self.height = height
    }
}

public enum GracenoteArtworkDownload {
    /// Only fetch SDK-provided public cover URLs; no application license is added to a URL.
    public static func validatedURL(_ value: String) throws -> URL {
        let string = value.contains("://") ? value : "https://" + value
        guard var components = URLComponents(string: string), let host = components.host?.lowercased(),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.port == nil,
              host.hasSuffix(".cddbp.net") || host.hasSuffix(".gracenote.com"),
              components.path.hasPrefix("/cds/") || components.path.hasPrefix("/webapi/") else {
            throw EnrichmentError("封面地址不是 SDK 支持的 Gracenote 内容地址")
        }
        components.scheme = "https"
        guard let url = components.url else { throw EnrichmentError("封面地址无效") }; return url
    }
    public static func download(_ asset: GracenoteCoverAsset) async throws -> EnrichmentArtwork {
        let url = try validatedURL(asset.url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: CoverRedirectPolicy(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("image/jpeg,image/png", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = response.url,
              try validatedURL(final.absoluteString) == final,
              response.expectedContentLength <= Int64(EnrichmentArtwork.maximumBytes) else { throw EnrichmentError("封面下载失败或文件过大") }
        var data = Data(); data.reserveCapacity(min(max(asset.estimatedBytes, 0), EnrichmentArtwork.maximumBytes))
        for try await byte in bytes {
            if data.count % 65536 == 0 { try Task.checkCancellation() }
            guard data.count < EnrichmentArtwork.maximumBytes else { throw EnrichmentError("封面超过 8 MiB") }
            data.append(byte)
        }
        return try EnrichmentArtwork(data: data)
    }
}

private final class CoverRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? GracenoteArtworkDownload.validatedURL(url.absoluteString)) == url else { completionHandler(nil); return }
        completionHandler(request)
    }
}
