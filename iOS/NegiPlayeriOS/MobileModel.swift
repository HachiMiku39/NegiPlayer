import Foundation
import UIKit
import Combine
#if canImport(LANCore)
import LANCore
#endif

@MainActor final class MobileModel:ObservableObject {
    @Published var albums:[RemoteAlbum]=[]
    @Published var tracks:[RemoteTrack]=[]
    @Published var total=0
    @Published var connected=false
    @Published var loading=false
    @Published var error:String?
    @Published var serverName=""
    @Published var query=""
    @Published var selectedAlbum:RemoteAlbum?
    @Published var queue:[RemoteTrack]=[]
    @Published var lyrics:[RemoteLyricLine]=[]
    @Published var artwork:UIImage?
    @Published var showPlayer=false
    @Published var shuffle=false
    @Published var repeatQueue=false
    let audio=MobilePlayer(), mv=MutedMV(), discovery=MacDiscovery()
    var credentials:LANCredentials?
    var client:PinnedSession?
    private var queryTask:Task<Void,Never>?, assetTask:Task<Void,Never>?, heartbeat:Task<Void,Never>?
    private var connectionGeneration=UUID(), browseGeneration=UUID()
    private let imageCache=NSCache<NSString,UIImage>()
    init() {
        imageCache.totalCostLimit=16*1024*1024; imageCache.countLimit=60
        audio.onEnded={ [weak self] in self?.next() }
        audio.onProgress={ [weak self] position,playing in self?.mv.sync(seconds:position,playing:playing) }
        audio.setNextPrevious(next:{ [weak self] in self?.next() },previous:{ [weak self] in self?.previous() })
    }
    func restore() async {
        do { if let saved=try ConnectionStore.load() { try await connect(saved) } } catch { self.error=error.localizedDescription }
    }
    func pair(url:String,fingerprint:String,code:String,expectedServerID:String?=nil) async {
        guard !loading else { return }; loading=true; defer { loading=false }
        do {
            let base=try NegiLAN.baseURL(url); let client=try PinnedSession(baseURL:base,fingerprint:fingerprint.lowercased())
            defer { client.session.invalidateAndCancel() }
            let p=try await client.pair(code:code,name:UIDevice.current.name)
            if let expectedServerID, p.serverID != expectedServerID { throw LANError.message("发现的 Mac 标识与配对结果不符") }
            let saved=LANCredentials(baseURL:base,fingerprint:fingerprint.lowercased(),token:p.token,serverID:p.serverID)
            try ConnectionStore.save(saved); try await connect(saved)
        } catch { self.error=error.localizedDescription }
    }
    private func connect(_ saved:LANCredentials) async throws {
        connectionGeneration=UUID(); let generation=connectionGeneration
        let session=try PinnedSession(baseURL:saved.baseURL,fingerprint:saved.fingerprint)
        var keepSession=false
        defer { if !keepSession { session.session.invalidateAndCancel() } }
        let info=try await session.json("/v1/info",as:ServerInfo.self,token:saved.token)
        guard info.id==saved.serverID, info.protocolVersion==NegiLAN.version else { throw LANError.message("Mac 标识或协议版本改变，请重新配对") }
        guard generation==connectionGeneration else { return }
        client?.session.invalidateAndCancel(); credentials=saved; client=session; keepSession=true; serverName=info.name; connected=true; selectedAlbum=nil; query=""
        try await reloadAlbums(); await searchTracks()
        heartbeat?.cancel(); heartbeat=Task { [weak self] in
            while !Task.isCancelled { await self?.reportState(); do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { break } }
        }
    }
    func disconnect() async {
        if let client,let credentials { _=try? await client.request("/v1/device",method:"DELETE",token:credentials.token) }
        do { try ConnectionStore.remove() } catch { self.error=error.localizedDescription; return }
        connectionGeneration=UUID(); browseGeneration=UUID(); loading=false; queryTask?.cancel(); assetTask?.cancel(); heartbeat?.cancel(); audio.stop(); mv.stop()
        client?.session.invalidateAndCancel(); client=nil; credentials=nil; connected=false; albums=[]; tracks=[]; queue=[]; lyrics=[]; artwork=nil; imageCache.removeAllObjects()
    }
    func reloadAlbums() async throws {
        guard let client,let credentials else { return }; let id=connectionGeneration
        let page=try await client.json("/v1/albums",as:AlbumPage.self,token:credentials.token)
        guard connectionGeneration==id else { return }; albums=page.albums
    }
    func queryChanged() {
        queryTask?.cancel(); queryTask=Task { do { try await Task.sleep(nanoseconds:250_000_000); try Task.checkCancellation(); await searchTracks() } catch {} }
    }
    func searchTracks() async {
        guard let client,let credentials else { return }; browseGeneration=UUID(); let id=browseGeneration; let connection=connectionGeneration; loading=true
        defer { if browseGeneration==id { loading=false } }
        do {
            var components=URLComponents(); components.path="/v1/tracks"; components.queryItems=[.init(name:"limit",value:"200"),.init(name:"q",value:query)]
            if let selectedAlbum { components.queryItems?.append(.init(name:"album",value:selectedAlbum.id)) }
            let page=try await client.json(components.string!,as:TrackPage.self,token:credentials.token); try Task.checkCancellation()
            guard browseGeneration==id, connectionGeneration==connection else { return }; tracks=page.tracks; total=page.total
        } catch is CancellationError {} catch { if browseGeneration==id { self.error=error.localizedDescription } }
    }
    func moreTracks() async {
        guard !loading, tracks.count<total,let client,let credentials else { return }; let id=browseGeneration; loading=true; defer { if id==browseGeneration { loading=false } }
        do {
            var c=URLComponents(); c.path="/v1/tracks"; c.queryItems=[.init(name:"offset",value:String(tracks.count)),.init(name:"limit",value:"200"),.init(name:"q",value:query)]
            if let selectedAlbum { c.queryItems?.append(.init(name:"album",value:selectedAlbum.id)) }
            let page=try await client.json(c.string!,as:TrackPage.self,token:credentials.token)
            guard id==browseGeneration else { return }; tracks.append(contentsOf:page.tracks); total=page.total
        } catch { self.error=error.localizedDescription }
    }
    func select(_ album:RemoteAlbum?) { selectedAlbum=album; query=""; queryTask?.cancel(); queryTask=Task { await searchTracks() } }
    func play(_ track:RemoteTrack,replaceQueue:Bool=true) {
        guard track.playable,let client,let credentials else { error="该格式尚不能在 iOS 播放，DSD／ISO 仍仅供识别"; return }
        if replaceQueue { queue=tracks.filter(\.playable) }; if !queue.contains(where:{$0.id==track.id}) { queue.append(track) }
        audio.load(track,client:client,token:credentials.token); showPlayer=true; lyrics=[]; artwork=nil; mv.stop(); assetTask?.cancel()
        assetTask=Task {
            async let cover=image(for:track.id)
            async let lines=try? client.json("/v1/tracks/\(track.id)/lyrics",as:RemoteLyrics.self,token:credentials.token)
            async let video=try? client.json("/v1/tracks/\(track.id)/video-info",as:VideoInfo.self,token:credentials.token)
            let (image,text,info)=await(cover,lines,video)
            guard !Task.isCancelled,audio.track?.id==track.id else { return }; artwork=image; lyrics=text?.lines ?? []; audio.setArtwork(image)
            if let info { mv.configure(info:info,client:client,token:credentials.token,id:track.id) }
        }
    }
    func enqueue(_ track:RemoteTrack) { if track.playable,!queue.contains(where:{$0.id==track.id}) { queue.append(track) } }
    func next() {
        guard !queue.isEmpty,let current=audio.track else { return }
        if shuffle,let random=queue.filter({$0.id != current.id}).randomElement() { play(random,replaceQueue:false); return }
        let i=queue.firstIndex(where:{$0.id==current.id}) ?? 0
        if i+1<queue.count { play(queue[i+1],replaceQueue:false) } else if repeatQueue { play(queue[0],replaceQueue:false) }
    }
    func previous() { if audio.position>3 { audio.seek(0); return }; guard let current=audio.track,let i=queue.firstIndex(where:{$0.id==current.id}),i>0 else { return }; play(queue[i-1],replaceQueue:false) }
    func image(for id:String) async -> UIImage? {
        if let cached=imageCache.object(forKey:id as NSString) { return cached }
        guard let client,let credentials,NegiLAN.validID(id) else { return nil }; let connection=connectionGeneration
        guard let (data,_)=try? await client.request("/v1/tracks/\(id)/artwork",token:credentials.token), data.count<4_000_000, let image=UIImage(data:data) else { return nil }
        guard connection==connectionGeneration else { return nil }; imageCache.setObject(image,forKey:id as NSString,cost:(image.cgImage?.bytesPerRow ?? 0)*(image.cgImage?.height ?? 0)); return image
    }
    private func reportState() async {
        guard let client,let credentials else { return }
        let state=MobileDeviceState(output:audio.output,sampleRate:audio.outputRate,eqEnabled:audio.preferences.eqEnabled,playing:audio.playing,trackTitle:audio.track?.title ?? "")
        if let body=try? JSONEncoder().encode(state) { _=try? await client.request("/v1/device/state",method:"POST",token:credentials.token,body:body) }
    }
}
