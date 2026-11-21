import Foundation
import Network
import Security
import MediaIO
import LyricCore
import LANCore

public struct LANHostState: Sendable {
    public var starting = false
    public var running=false; public var port:UInt16=0; public var fingerprint=""; public var code=""; public var message="服务已关闭"
    public var devices:[PairedDevice]=[]; public var outputs:[String:MobileDeviceState]=[:]
    public init() {}
}
private struct Reply {
    var status:Int=200; var type="application/json"; var body=Data(); var headers:[String:String]=[:]; var length:Int64?
    func bytes(head:Bool) -> Data {
        let reason=[200:"OK",204:"No Content",206:"Partial Content",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",413:"Payload Too Large",415:"Unsupported Media Type",416:"Range Not Satisfiable",429:"Too Many Requests",431:"Request Header Fields Too Large",500:"Internal Server Error",503:"Unavailable"][status] ?? "Error"
        var text="HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(length ?? Int64(body.count))\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for (key,value) in headers.sorted(by:{$0.key<$1.key}) { text += "\(key): \(value)\r\n" }
        text += "\r\n"; var data=Data(text.utf8); if !head { data.append(body) }; return data
    }
}
public actor LANServer {
    private let directory:URL; private let pairing:PairingStore; private let queue=DispatchQueue(label:"NegiPlayer.LAN")
    private var listener: NWListener?
    private var listenerGeneration: UUID?
    private var stopping = false
    private var identity: LANIdentity?
    private var identityTask: Task<LANIdentity, Error>?
    private var entries:[String:CatalogEntry]=[:]
    private var artwork:ArtworkRepository; private var revision=UUID().uuidString
    private var sortedTracks:[RemoteTrack]=[]
    private var connections:[UUID:NWConnection]=[:]; private var connectionDevices:[UUID:String]=[:]
    private var state=LANHostState(); private let name:String
    public init(directory:URL,artwork:ArtworkRepository,name:String="NegiPlayer Mac") throws {
        self.directory=directory; self.artwork=artwork; self.name=name
        pairing=try PairingStore(url:directory.appendingPathComponent("paired-devices.json"))
    }
    public func update(_ values:[CatalogEntry]) { entries=Dictionary(values.map{($0.media.id,$0)},uniquingKeysWith:{ first,_ in first }); sortedTracks=entries.values.map(\.remote).sorted { ($0.album,$0.discNumber,$0.trackNumber,$0.title,$0.id)<($1.album,$1.discNumber,$1.trackNumber,$1.title,$1.id) }; revision=UUID().uuidString }
    public func snapshot() async -> LANHostState {
        let generation = listenerGeneration
        let devices = await pairing.list()
        let code = await pairing.currentCode()
        var snapshot = state
        snapshot.devices = devices
        snapshot.code = generation == listenerGeneration && snapshot.running ? code : ""
        return snapshot
    }
    public func start(port:UInt16=40439,advertise:Bool=true) async throws {
        guard !stopping, listenerGeneration == nil else { return }
        let generation = UUID()
        listenerGeneration = generation
        state.starting = true
        state.message = "正在启动 HTTPS 服务…"
        defer {
            if listenerGeneration == generation, listener == nil {
                listenerGeneration = nil
                state = LANHostState()
            }
        }
        let id = try await loadIdentity()
        try Task.checkCancellation()
        guard listenerGeneration == generation else { return }
        let tls=NWProtocolTLS.Options(); sec_protocol_options_set_local_identity(tls.securityProtocolOptions,sec_identity_create(id.identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv12)
        let parameters=NWParameters(tls:tls); parameters.prohibitedInterfaceTypes=[.cellular]; parameters.includePeerToPeer=false
        let nw=try NWListener(using:parameters,on:port==0 ? .any : NWEndpoint.Port(rawValue:port)!)
        if advertise { nw.service = .init(name:name,type:NegiLAN.serviceType,domain:"local.",txtRecord:NetService.data(fromTXTRecord:["fp":Data(id.fingerprint.utf8),"id":Data(id.serverID.utf8),"v":Data("1".utf8)])) }
        listener = nw
        state.fingerprint = id.fingerprint
        nw.stateUpdateHandler = { [weak self, weak nw] event in
            let port = nw?.port?.rawValue ?? 0
            Task { await self?.listenerState(event, port: port, generation: generation) }
        }
        nw.newConnectionHandler = { [weak self] connection in
            Task {
                guard let self else { connection.cancel(); return }
                await self.accept(connection, generation: generation)
            }
        }
        nw.start(queue: queue)
    }
    private func loadIdentity() async throws -> LANIdentity {
        if let identity { return identity }
        if let identityTask { return try await identityTask.value }
        let directory = self.directory
        let work = Task.detached(priority: .utility) { try LANIdentity.load(directory: directory) }
        identityTask = work
        defer { identityTask = nil }
        let result = try await work.value
        identity = result
        return result
    }
    private func listenerState(_ event: NWListener.State, port: UInt16, generation: UUID) {
        guard generation == listenerGeneration else { return }
        switch event {
        case .ready:
            state.starting = false
            state.running = true
            state.port = port
            state.message = "Mac 提供只读曲库与 PCM 流，音频由 iOS 处理"
        case .failed:
            clearListener()
            state.message = "服务启动失败，请检查系统局域网权限和防火墙"
        case .cancelled:
            clearListener()
        default:
            break
        }
    }
    private func clearListener() {
        listenerGeneration = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        connectionDevices.removeAll()
        state = LANHostState()
    }
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        clearListener()
        await pairing.closePairing()
        stopping = false
    }
    public func renewCode() async throws -> String {
        guard state.running, let generation = listenerGeneration else { throw LANError.message("请先开启局域网服务") }
        let code = try await pairing.renew()
        guard generation == listenerGeneration else { throw CancellationError() }
        return code
    }
    public func revoke(_ id:String) async throws {
        try await pairing.revoke(id); state.outputs.removeValue(forKey:id)
        for (key,device) in connectionDevices where device==id { connections[key]?.cancel() }
    }
    private func accept(_ c:NWConnection, generation: UUID) {
        guard generation == listenerGeneration, connections.count<24, case .hostPort(let host,_) = c.endpoint, NegiLAN.localAddress(String(describing:host)) else { c.cancel(); return }
        let key=UUID(); connections[key]=c; c.start(queue:queue)
        Task {
            let timeout=Task { try? await Task.sleep(nanoseconds:25_000_000_000); if !Task.isCancelled { c.cancel() } }
            defer { timeout.cancel(); c.cancel(); connections.removeValue(forKey:key); connectionDevices.removeValue(forKey:key) }
            do {
                var data=Data(); var request:HTTPRequest?
                while request==nil {
                    let chunk=try await receive(c); guard !chunk.isEmpty else { throw LANError.status(400) }; data.append(chunk)
                    guard data.count<=36864 else { throw LANError.status(413) }; request=try HTTPRequest.parse(data)
                }
                let r=request!; let response=try await route(r,key:key)
                guard connections[key] != nil else { return }
                try await send(c,response.bytes(head:r.method=="HEAD"))
                // A send completion means the stack accepted the bytes, not that the peer received them.
                // The final message closes our write side; keep the connection until the peer closes
                // its side (or the existing bounded timeout fires) rather than cancelling buffered TLS.
                _ = try? await receive(c)
            } catch {
                let status:Int; if case LANError.status(let n)=error { status=n } else { status=500 }
                // No local paths, pairing codes, tokens, or filesystem diagnostics in network errors.
                try? await send(c,Reply(status:status,body:Data("{\"error\":\"request failed\"}".utf8)).bytes(head:false))
                _ = try? await receive(c)
            }
        }
    }
    private func receive(_ c:NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in c.receive(minimumIncompleteLength:1,maximumLength:8192) { data,_,done,error in if let error { cont.resume(throwing:error) } else { cont.resume(returning:data ?? Data()) } } }
    }
    private func send(_ c:NWConnection,_ data:Data) async throws {
        try await withCheckedThrowingContinuation { (cont:CheckedContinuation<Void,Error>) in
            // Finish TLS/TCP after the complete response, including bodies larger than a send buffer.
            c.send(content:data,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed { error in if let error { cont.resume(throwing:error) } else { cont.resume() } })
        }
    }
    private func json<T:Encodable>(_ value:T) throws -> Reply { .init(body:try JSONEncoder().encode(value)) }
    private func route(_ r:HTTPRequest,key:UUID) async throws -> Reply {
        guard connections[key] != nil else { throw CancellationError() }
        guard let components=r.components else { throw LANError.status(400) }
        let path=components.path
        if path=="/v1/pair" {
            guard r.method=="POST", r.headers["content-type"]?.hasPrefix("application/json")==true, let identity else { throw LANError.status(400) }
            let p=try JSONDecoder().decode(PairRequest.self,from:r.body); let token=try await pairing.pair(p); state.code=""
            return try json(PairResponse(token:token,serverID:identity.serverID))
        }
        guard let device=await pairing.authorize(r.headers["authorization"]) else { throw LANError.status(401) }
        guard connections[key] != nil else { throw CancellationError() }
        connectionDevices[key]=device
        if path=="/v1/device",r.method=="DELETE" {
            try await pairing.revoke(device); state.outputs.removeValue(forKey:device)
            for (other,owner) in connectionDevices where owner==device && other != key { connections[other]?.cancel() }
            return .init(status:204)
        }
        if path=="/v1/device/state",r.method=="POST" {
            let s=try JSONDecoder().decode(MobileDeviceState.self,from:r.body)
            state.outputs[device]=MobileDeviceState(output:s.output,sampleRate:s.sampleRate,eqEnabled:s.eqEnabled,playing:s.playing,trackTitle:s.trackTitle); return .init(status:204)
        }
        guard r.method=="GET" || r.method=="HEAD" else { throw LANError.status(405) }
        if path=="/v1/info",let identity { return try json(ServerInfo(id:identity.serverID,name:name)) }
        let all=sortedTracks
        if path=="/v1/albums" {
            let albums=Dictionary(grouping:all,by:\.albumID).values.compactMap { group -> RemoteAlbum? in guard let first=group.first else { return nil }; return .init(id:first.albumID,title:first.album,artist:first.artist,coverTrackID:first.id,count:group.count) }.sorted{$0.title<$1.title}
            return try json(AlbumPage(albums:albums,revision:revision))
        }
        if path=="/v1/tracks" {
            let query=Dictionary(components.queryItems?.map{($0.name,$0.value ?? "")} ?? [],uniquingKeysWith:{$1})
            let offset=Int(query["offset"] ?? "0") ?? -1, limit=Int(query["limit"] ?? "200") ?? -1
            guard offset>=0, (1...500).contains(limit), (query["q"]?.count ?? 0)<=200 else { throw LANError.status(400) }
            let matches=all.filter { track in
                if let album=query["album"], track.albumID != album { return false }
                if let q=query["q"], !q.isEmpty { return (track.title+" "+track.artist+" "+track.album).localizedStandardContains(q) }; return true
            }
            let start=min(offset,matches.count); let end=min(matches.count,start+limit)
            return try json(TrackPage(tracks:Array(matches[start..<end]),total:matches.count,offset:start,revision:revision))
        }
        let parts=path.split(separator:"/")
        guard parts.count==4, parts[0]=="v1",parts[1]=="tracks", NegiLAN.validID(String(parts[2])), let entry=entries[String(parts[2])] else { throw LANError.status(404) }
        let source=try entry.authorizedSource()
        switch parts[3] {
        case "artwork":
            let group=entries.values.filter{$0.media.releaseKey==entry.media.releaseKey && $0.media.rootID==entry.media.rootID}
            let urls=[source]+group.filter{$0.media.id != entry.media.id}.compactMap{try? $0.authorizedSource()}
            guard let art=await artwork.artwork(sources:urls,root:entry.root) else { throw LANError.status(404) }
            return .init(type:"image/png",body:art.data)
        case "lyrics":
            let result=try await Task.detached { try SidecarLyrics.load(for:source,title:entry.media.title,root:entry.root) }.value
            let lines=result?.document.rows.enumerated().map { RemoteLyricLine(id:$0.offset,time:$0.element.start.map{$0.seconds+result!.document.offset.seconds},text:$0.element.text) } ?? []
            return try json(RemoteLyrics(lines:lines))
        case "stream-info", "stream":
            guard entry.remote.playable else { throw LANError.status(415) }
            let pcm=try await Task.detached { try PCMSource(entry:entry) }.value
            if parts[3]=="stream-info" { return try json(pcm.info) }
            if r.method=="HEAD" { return .init(type:"application/octet-stream",headers:["Accept-Ranges":"bytes"],length:pcm.info.length) }
            guard let raw=r.headers["range"] else { throw LANError.status(400) }
            let range=try ByteRange.parse(raw,length:pcm.info.length); guard range.count<=262144 else { throw LANError.status(413) }
            let data=try await Task.detached { try pcm.read(start:range.start,count:Int(range.count)) }.value
            return .init(status:206,type:"application/octet-stream",body:data,headers:["Accept-Ranges":"bytes","Content-Range":"bytes \(range.start)-\(range.end)/\(pcm.info.length)"])
        case "video-info", "video":
            guard let video=try Self.video(for:entry) else { if parts[3]=="video-info" { return try json(VideoInfo(available:false)) }; throw LANError.status(404) }
            let size=Int64(try video.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
            if parts[3]=="video-info" { return try json(VideoInfo(available:true,length:size,contentType:video.pathExtension.lowercased()=="mov" ? "video/quicktime" : "video/mp4")) }
            let type=video.pathExtension.lowercased()=="mov" ? "video/quicktime" : "video/mp4"
            if r.method=="HEAD" { return .init(type:type,headers:["Accept-Ranges":"bytes"],length:size) }
            guard let raw=r.headers["range"] else { throw LANError.status(400) }; let range=try ByteRange.parse(raw,length:size); guard range.count<=262144 else { throw LANError.status(413) }
            let data=try await Task.detached { let f=try FileHandle(forReadingFrom:video); defer { try? f.close() }; try f.seek(toOffset:UInt64(range.start)); let d=try f.read(upToCount:Int(range.count)) ?? Data(); guard d.count==range.count else { throw LANError.status(503) }; return d }.value
            return .init(status:206,type:type,body:data,headers:["Accept-Ranges":"bytes","Content-Range":"bytes \(range.start)-\(range.end)/\(size)"])
        default: throw LANError.status(404)
        }
    }
    public static func video(for entry:CatalogEntry) throws -> URL? {
        let source=try entry.authorizedSource(), stem=source.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        let root=entry.root.resolvingSymlinksInPath().path
        let matches=try FileManager.default.contentsOfDirectory(at:source.deletingLastPathComponent(),includingPropertiesForKeys:[.isRegularFileKey],options:.skipsHiddenFiles).filter {
            ["mp4","m4v","mov"].contains($0.pathExtension.lowercased()) && $0.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()==stem && $0.resolvingSymlinksInPath().path.hasPrefix(root+"/") && (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true
        }
        return matches.count==1 ? matches[0] : nil
    }
}
