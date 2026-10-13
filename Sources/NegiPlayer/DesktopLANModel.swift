import Foundation
import AppKit
import Combine
import Security
import LANCore

private enum DesktopConnectionStore {
    static let service="com.negiplayer.desktop.lan.v1"
    static var query:[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"endpoint"] }
    static func load() throws -> LANCredentials? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?; let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess,let data=result as? Data else { throw LANError.message("无法读取已保存的主机连接") }
        return try JSONDecoder().decode(LANCredentials.self,from:data)
    }
    static func save(_ credentials:LANCredentials) throws {
        let data=try JSONEncoder().encode(credentials)
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound { var q=query; q[kSecValueData as String]=data; q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else { throw LANError.message("无法保存主机配对") } }
        else if status != errSecSuccess { throw LANError.message("无法保存主机配对") }
    }
    static func remove() throws { let status=SecItemDelete(query as CFDictionary); guard status==errSecSuccess || status==errSecItemNotFound else { throw LANError.message("无法删除主机配对") } }
}

@MainActor final class DesktopLANModel:ObservableObject {
    @Published var albums:[RemoteAlbum]=[]
    @Published var tracks:[RemoteTrack]=[]
    @Published var lyrics:[RemoteLyricLine]=[]
    @Published var cover:NSImage?
    @Published var connected=false
    @Published var loading=false
    @Published var error:String?
    @Published var selectedAlbum:RemoteAlbum?
    @Published var total=0
    @Published var hostName=""
    @Published var query=""
    let player=DesktopLANPlayer()
    var onPlay:(()->Void)?
    private var client:PinnedSession?, credentials:LANCredentials?
    private var assetTask:Task<Void,Never>?, queryTask:Task<Void,Never>?, heartbeat:Task<Void,Never>?
    private var connectionGeneration=UUID(), browseGeneration=UUID()
    private var restored=false
    private let albumCovers=NSCache<NSString,NSImage>()
    func artwork(_ id:String) async -> NSImage? {
        if let image=albumCovers.object(forKey:id as NSString) { return image }
        guard let client,let credentials else { return nil }; let generation=connectionGeneration
        guard let data=try? await client.request("/v1/tracks/\(id)/artwork",token:credentials.token),data.0.count<=8_000_000,
              generation==connectionGeneration,let image=NSImage(data:data.0) else { return nil }
        albumCovers.countLimit=32; albumCovers.totalCostLimit=32_000_000
        albumCovers.setObject(image,forKey:id as NSString,cost:data.0.count); return image
    }
    init() { player.onEnded = { [weak self] in self?.next(1) } }
    func restore() async {
        guard !restored else { return }; restored=true
        do { if let saved=try DesktopConnectionStore.load() { try await connect(saved) } } catch { self.error=error.localizedDescription }
    }
    func pair(address:String,fingerprint:String,code:String,confirmed:Bool) async {
        guard !loading, confirmed, code.count==8,code.allSatisfy({$0.isASCII && $0.isNumber}) else { return }
        loading=true; defer { loading=false }
        do {
            let base=try NegiLAN.baseURL(address), session=try PinnedSession(baseURL:base,fingerprint:fingerprint.lowercased())
            defer { session.session.invalidateAndCancel() }
            let pair=try await session.pair(code:code,name:(Host.current().localizedName ?? "macOS")+" · Playback")
            let saved=LANCredentials(baseURL:base,fingerprint:fingerprint.lowercased(),token:pair.token,serverID:pair.serverID)
            try DesktopConnectionStore.save(saved); try await connect(saved)
        } catch { self.error=error.localizedDescription }
    }
    private func connect(_ saved:LANCredentials) async throws {
        let session=try PinnedSession(baseURL:saved.baseURL,fingerprint:saved.fingerprint)
        do {
            let info=try await session.json("/v1/info",as:ServerInfo.self,token:saved.token)
            guard info.id==saved.serverID,info.protocolVersion==1 else { throw LANError.message("主机标识改变，请重新配对") }
            connectionGeneration=UUID(); player.stop(); client?.session.invalidateAndCancel(); client=session; credentials=saved
            hostName=info.name; connected=true; selectedAlbum=nil; query=""; try await refresh()
            heartbeat?.cancel(); heartbeat=Task { [weak self] in while !Task.isCancelled { await self?.report(); do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { break } } }
        } catch { session.session.invalidateAndCancel(); throw error }
    }
    func refresh() async throws {
        guard let client,let credentials else { return }; let id=connectionGeneration
        let page=try await client.json("/v1/albums",as:AlbumPage.self,token:credentials.token)
        guard id==connectionGeneration else { return }; albums=page.albums; await search()
    }
    func search() async {
        guard let client,let credentials else { return }; browseGeneration=UUID(); let id=browseGeneration
        loading=true; defer { if id==browseGeneration { loading=false } }
        do { let page=try await client.json(trackPath(offset:0),as:TrackPage.self,token:credentials.token)
            guard id==browseGeneration else { return }; tracks=page.tracks; total=page.total
        } catch { if id==browseGeneration { self.error=error.localizedDescription } }
    }
    func more() async {
        guard !loading, tracks.count<total, let client,let credentials else { return }; let id=browseGeneration; loading=true; defer { loading=false }
        do { let page=try await client.json(trackPath(offset:tracks.count),as:TrackPage.self,token:credentials.token)
            guard id==browseGeneration else { return }; tracks+=page.tracks
        } catch { self.error=error.localizedDescription }
    }
    private func trackPath(offset:Int) -> String {
        var c=URLComponents(); c.path="/v1/tracks"; c.queryItems=[.init(name:"limit",value:"200"),.init(name:"offset",value:String(offset)),.init(name:"q",value:String(query.prefix(200)))]
        if let selectedAlbum { c.queryItems?.append(.init(name:"album",value:selectedAlbum.id)) }; return c.string!
    }
    func queryChanged() { queryTask?.cancel(); queryTask=Task { do { try await Task.sleep(nanoseconds:250_000_000); try Task.checkCancellation(); await search() } catch {} } }
    func select(_ album:RemoteAlbum?) { selectedAlbum=album; query=""; queryTask?.cancel(); queryTask=Task { await search() } }
    func play(_ track:RemoteTrack) {
        guard let client,let credentials,track.playable else { return }; onPlay?(); cover=nil; lyrics=[]; assetTask?.cancel()
        player.load(track,client:client,token:credentials.token); let id=track.id
        assetTask=Task {
            async let image=try? client.request("/v1/tracks/\(id)/artwork",token:credentials.token)
            async let lines=try? client.json("/v1/tracks/\(id)/lyrics",as:RemoteLyrics.self,token:credentials.token)
            let (art,lrc)=await(image,lines); guard !Task.isCancelled,player.track?.id==id else { return }
            if let art,art.0.count<=8_000_000 { cover=NSImage(data:art.0) }; lyrics=lrc?.lines ?? []
        }
    }
    func next(_ step:Int) { let queue=tracks.filter(\.playable); guard let id=player.track?.id,let index=queue.firstIndex(where:{$0.id==id}),queue.indices.contains(index+step) else { return }; play(queue[index+step]) }
    func disconnect() async {
        if let client,let credentials { _=try? await client.request("/v1/device",method:"DELETE",token:credentials.token) }
        do { try DesktopConnectionStore.remove() } catch { self.error=error.localizedDescription; return }
        connectionGeneration=UUID(); browseGeneration=UUID(); albumCovers.removeAllObjects(); player.stop(); queryTask?.cancel(); assetTask?.cancel(); heartbeat?.cancel()
        client?.session.invalidateAndCancel(); client=nil; credentials=nil; connected=false; albums=[]; tracks=[]; cover=nil; lyrics=[]
    }
    private func report() async {
        guard let client,let credentials else { return }
        let state=MobileDeviceState(output:player.output,sampleRate:player.outputRate,eqEnabled:player.preferences.eqEnabled,playing:player.playing,trackTitle:player.track?.title ?? "")
        guard let data=try? JSONEncoder().encode(state) else { return }; _=try? await client.request("/v1/device/state",method:"POST",token:credentials.token,body:data)
    }
}
