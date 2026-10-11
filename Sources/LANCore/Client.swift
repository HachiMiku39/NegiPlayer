import Foundation
import Security

/// Trust only the exact certificate confirmed on the Mac. Never accept every certificate.
public final class PinnedSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public let baseURL:URL; public let fingerprint:String
    public lazy var session:URLSession = {
        let c=URLSessionConfiguration.ephemeral; c.urlCache=nil; c.httpCookieStorage=nil
        c.timeoutIntervalForRequest=20; c.timeoutIntervalForResource=120; c.httpMaximumConnectionsPerHost=6
        return URLSession(configuration:c,delegate:self,delegateQueue:nil)
    }()
    public init(baseURL:URL,fingerprint:String) throws {
        self.baseURL=try NegiLAN.baseURL(baseURL.absoluteString)
        guard NegiLAN.validFingerprint(fingerprint) else { throw LANError.message("Mac 证书指纹无效") }
        self.fingerprint=fingerprint; super.init()
    }
    public func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        guard challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased()==baseURL.host?.lowercased(),
              challenge.protectionSpace.port==(baseURL.port ?? 443), let trust=challenge.protectionSpace.serverTrust,
              let chain=SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert=chain.first,
              NegiLAN.fingerprint(SecCertificateCopyData(cert) as Data)==fingerprint else { completionHandler(.cancelAuthenticationChallenge,nil); return }
        completionHandler(.useCredential,URLCredential(trust:trust))
    }
    public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
    public func request(_ path:String,method:String="GET",token:String?=nil,body:Data?=nil,range:ByteRange?=nil) async throws -> (Data,HTTPURLResponse) {
        guard path.hasPrefix("/v1/"), let url=URL(string:path,relativeTo:baseURL)?.absoluteURL, url.host==baseURL.host, url.port==baseURL.port else { throw LANError.message("无效服务请求") }
        var r=URLRequest(url:url); r.httpMethod=method; r.httpBody=body
        if let token { r.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
        if body != nil { r.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if let range { r.setValue("bytes=\(range.start)-\(range.end)",forHTTPHeaderField:"Range") }
        let (data,response)=try await session.data(for:r)
        guard let h=response as? HTTPURLResponse, (200...299).contains(h.statusCode) else { throw LANError.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return (data,h)
    }
    public func json<T:Decodable>(_ path:String,as:T.Type,token:String?=nil) async throws -> T {
        let (data,_)=try await request(path,token:token); guard data.count<=8_000_000 else { throw LANError.message("服务响应过大") }; return try JSONDecoder().decode(T.self,from:data)
    }
    public func pair(code:String,name:String) async throws -> PairResponse {
        let body=try JSONEncoder().encode(PairRequest(code:code,deviceName:name))
        let (data,_)=try await request("/v1/pair",method:"POST",body:body)
        let p=try JSONDecoder().decode(PairResponse.self,from:data)
        guard p.protocolVersion==NegiLAN.version, NegiLAN.validID(p.serverID), p.token.count>=40 else { throw LANError.message("Mac 协议版本不兼容") }; return p
    }
}
