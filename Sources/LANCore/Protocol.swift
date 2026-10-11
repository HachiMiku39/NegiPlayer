import Foundation
import CryptoKit
import Darwin

public enum NegiLAN {
    public static let serviceType = "_negiplayer._tcp."
    public static let version = 1
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public static func validFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && ("0123456789abcdef".contains($0)) }
    }
    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    public static func baseURL(_ text: String) throws -> URL {
        guard let u = URLComponents(string:text), u.scheme == "https", let host = u.host,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/", let port = u.port, (1...65535).contains(port),
              localHost(host) else { throw LANError.message("请输入 Mac 显示的局域网 HTTPS 地址及端口") }
        var clean = u; clean.path = ""; guard let url = clean.url else { throw LANError.message("地址无效") }; return url
    }
    public static func localHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".local.") { return true }
        return localAddress(h)
    }
    public static func localAddress(_ value: String) -> Bool {
        let h = value.lowercased().split(separator:"%",maxSplits:1).first.map(String.init) ?? ""
        if h.contains(":") {
            var address=in6_addr()
            guard h.withCString({inet_pton(AF_INET6,$0,&address)})==1 else { return false }
            let bytes=withUnsafeBytes(of:address){Array($0)}
            if bytes.prefix(15).allSatisfy({$0==0}), bytes[15]==1 { return true }
            if bytes.prefix(10).allSatisfy({$0==0}), bytes[10]==255,bytes[11]==255 {
                return localAddress(bytes[12...15].map{String($0)}.joined(separator:"."))
            }
            return (bytes[0]&0xfe)==0xfc || (bytes[0]==0xfe && (bytes[1]&0xc0)==0x80)
        }
        let parts = h.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = Int(parts[0]), let b = Int(parts[1]), parts.allSatisfy({ (0...255).contains(Int($0) ?? -1) }) else { return false }
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
    }
}
public enum LANError: LocalizedError {
    case message(String), status(Int)
    public var errorDescription: String? {
        switch self { case .message(let s): return s; case .status(let n): return n == 401 ? "配对已失效，请重新连接 Mac" : "Mac 返回错误（\(n)）" }
    }
}
public struct RemoteTrack: Codable, Identifiable, Hashable, Sendable {
    public var id: String; public var title: String; public var artist: String; public var album: String
    public var albumID: String; public var codec: String; public var sampleRate: Double; public var duration: Double
    public var trackNumber: Int; public var discNumber: Int; public var playable: Bool
    public init(id:String,title:String,artist:String,album:String,albumID:String,codec:String,sampleRate:Double,duration:Double,trackNumber:Int,discNumber:Int,playable:Bool) {
        self.id=id; self.title=title; self.artist=artist; self.album=album; self.albumID=albumID; self.codec=codec; self.sampleRate=sampleRate; self.duration=duration; self.trackNumber=trackNumber; self.discNumber=discNumber; self.playable=playable
    }
}
public struct RemoteAlbum: Codable, Identifiable, Sendable {
    public var id:String; public var title:String; public var artist:String; public var coverTrackID:String; public var count:Int
    public init(id:String,title:String,artist:String,coverTrackID:String,count:Int) { self.id=id; self.title=title; self.artist=artist; self.coverTrackID=coverTrackID; self.count=count }
}
public struct TrackPage: Codable, Sendable {
    public var tracks:[RemoteTrack]; public var total:Int; public var offset:Int; public var revision:String
    public init(tracks:[RemoteTrack],total:Int,offset:Int,revision:String) { self.tracks=tracks; self.total=total; self.offset=offset; self.revision=revision }
}
public struct AlbumPage: Codable, Sendable { public var albums:[RemoteAlbum]; public var revision:String; public init(albums:[RemoteAlbum],revision:String) { self.albums=albums; self.revision=revision } }
public struct RemoteLyricLine: Codable, Identifiable, Sendable {
    public var id:Int; public var time:Double?; public var text:String
    public init(id:Int,time:Double?,text:String) { self.id=id; self.time=time; self.text=text }
}
public struct RemoteLyrics: Codable, Sendable { public var lines:[RemoteLyricLine]; public init(lines:[RemoteLyricLine]) { self.lines=lines } }
public struct PairRequest: Codable, Sendable { public var code:String; public var deviceName:String; public init(code:String,deviceName:String) { self.code=code; self.deviceName=deviceName } }
public struct PairResponse: Codable, Sendable { public var token:String; public var serverID:String; public var protocolVersion:Int; public init(token:String,serverID:String) { self.token=token; self.serverID=serverID; protocolVersion=NegiLAN.version } }
public struct ServerInfo: Codable, Sendable { public var id:String; public var name:String; public var protocolVersion:Int; public init(id:String,name:String) { self.id=id; self.name=name; protocolVersion=NegiLAN.version } }
public struct LANCredentials: Codable, Sendable {
    public var baseURL:URL; public var fingerprint:String; public var token:String; public var serverID:String
    public init(baseURL:URL,fingerprint:String,token:String,serverID:String) { self.baseURL=baseURL; self.fingerprint=fingerprint; self.token=token; self.serverID=serverID }
}
