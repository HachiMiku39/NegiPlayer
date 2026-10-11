import Foundation
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(LANCore)
import LANCore
#endif

final class VideoResourceLoader:NSObject,AVAssetResourceLoaderDelegate,@unchecked Sendable {
    // Request/task bookkeeping stays on the resource loader serial queue. Immutable connection inputs are shared.
    let client:PinnedSession, token:String, path:String, info:VideoInfo
    let queue=DispatchQueue(label:"NegiPlayer.MV.loader")
    private var tasks:[ObjectIdentifier:Task<Void,Never>]=[:]
    init(client:PinnedSession,token:String,path:String,info:VideoInfo) { self.client=client; self.token=token; self.path=path; self.info=info }
    func resourceLoader(_ resourceLoader:AVAssetResourceLoader,shouldWaitForLoadingOfRequestedResource loadingRequest:AVAssetResourceLoadingRequest) -> Bool {
        let key=ObjectIdentifier(loadingRequest)
        guard tasks.count<8 else { loadingRequest.finishLoading(with:LANError.message("视频请求过多")); return true }
        if let content=loadingRequest.contentInformationRequest { content.contentType=info.contentType=="video/quicktime" ? UTType.quickTimeMovie.identifier : UTType.mpeg4Movie.identifier; content.contentLength=info.length; content.isByteRangeAccessSupported=true }
        guard let dataRequest=loadingRequest.dataRequest else { loadingRequest.finishLoading(); return true }
        let start=max(dataRequest.requestedOffset,dataRequest.currentOffset)
        let requestedEnd=dataRequest.requestsAllDataToEndOfResource ? info.length : min(info.length,dataRequest.requestedOffset+Int64(dataRequest.requestedLength))
        guard start>=0, start<=requestedEnd else { loadingRequest.finishLoading(with:LANError.status(416)); return true }
        tasks[key]=Task { [weak self] in
            guard let self else { return }
            do {
                var offset=start
                while offset<requestedEnd {
                    try Task.checkCancellation(); let range=ByteRange(start:offset,count:min(262144,requestedEnd-offset))
                    let (data,h)=try await client.request(path,token:token,range:range)
                    guard h.statusCode==206, data.count==range.count, h.value(forHTTPHeaderField:"Content-Range")=="bytes \(range.start)-\(range.end)/\(info.length)" else { throw LANError.message("MV 流范围不一致") }
                    try Task.checkCancellation()
                    await withCheckedContinuation { cont in self.queue.async { if self.tasks[key] != nil { dataRequest.respond(with:data) }; cont.resume() } }
                    offset+=Int64(data.count)
                }
                self.queue.async { if self.tasks.removeValue(forKey:key) != nil { loadingRequest.finishLoading() } }
            } catch is CancellationError {} catch { self.queue.async { if self.tasks.removeValue(forKey:key) != nil { loadingRequest.finishLoading(with:error) } } }
        }; return true
    }
    func resourceLoader(_ resourceLoader:AVAssetResourceLoader,didCancel loadingRequest:AVAssetResourceLoadingRequest) { tasks.removeValue(forKey:ObjectIdentifier(loadingRequest))?.cancel() }
    func stop() { queue.async { self.tasks.values.forEach{$0.cancel()}; self.tasks.removeAll() } }
}
@MainActor final class MutedMV:ObservableObject {
    @Published var available=false
    @Published var enabled=false
    @Published var failed=false
    @Published var preparing=false
    let player=AVPlayer()
    private var loader:VideoResourceLoader?
    private var sourceAsset:AVURLAsset?
    private var info:VideoInfo?
    private var client:PinnedSession?
    private var token="", id=""
    private var observer:NSKeyValueObservation?
    private var pendingSeek=false
    private var preparation:Task<Void,Never>?
    private var generation=UUID()
    init() {
        player.isMuted=true; player.volume=0; player.automaticallyWaitsToMinimizeStalling=true
        observer=player.observe(\.isMuted,options:[.new]) { p,_ in if !p.isMuted { p.isMuted=true; p.volume=0 } }
    }
    func configure(info:VideoInfo,client:PinnedSession,token:String,id:String) {
        stop(); self.info=info; self.client=client; self.token=token; self.id=id; available=info.available
    }
    func toggle(at seconds:Double) {
        if enabled || preparing { stopVideo(); enabled=false; return }
        guard let info, info.available, let client else { return }
        loader=VideoResourceLoader(client:client,token:token,path:"/v1/tracks/\(id)/video",info:info)
        let asset=AVURLAsset(url:URL(string:"negi-mv://video/\(id).mp4")!); asset.resourceLoader.setDelegate(loader,queue:loader!.queue); sourceAsset=asset
        preparing=true; failed=false; let current=generation
        preparation=Task {
            do {
                guard let video=try await asset.loadTracks(withMediaType:.video).first else { throw LANError.message("MV 没有视频轨道") }
                let range=try await video.load(.timeRange), transform=try await video.load(.preferredTransform)
                try Task.checkCancellation(); guard generation==current else { return }
                // Insert only the video track. No MV audio track enters the playback item.
                let composition=AVMutableComposition()
                guard let track=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw LANError.message("MV 轨道创建失败") }
                try track.insertTimeRange(range,of:video,at:range.start); track.preferredTransform=transform
                let item=AVPlayerItem(asset:composition)
                player.replaceCurrentItem(with:item); player.isMuted=true; player.volume=0
                for _ in 0..<80 {
                    try Task.checkCancellation(); guard generation==current else { return }
                    if item.status == .readyToPlay { break }
                    if item.status == .failed { throw item.error ?? LANError.message("MV 载入失败") }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                guard item.status == .readyToPlay else { throw LANError.message("MV 载入超时") }
                enabled=true; preparing=false
                _ = await player.seek(to:CMTime(seconds:seconds,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
            } catch is CancellationError {} catch { if generation==current { failed=true; stopVideo() } }
        }
    }
    func sync(seconds:Double,playing:Bool) {
        guard enabled else { return }; player.isMuted=true; player.volume=0
        if player.currentItem?.status == .failed { failed=true; stopVideo(); return }
        let current=player.currentTime().seconds
        if !pendingSeek, current.isFinite, abs(current-seconds)>0.35 { pendingSeek=true; player.seek(to:CMTime(seconds:seconds,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] _ in Task { @MainActor in self?.pendingSeek=false } } }
        if playing { if player.rate==0 { player.play() } } else { player.pause() }
    }
    private func stopVideo() { generation=UUID(); preparation?.cancel(); preparation=nil; preparing=false; player.pause(); player.replaceCurrentItem(with:nil); loader?.stop(); loader=nil; sourceAsset=nil; pendingSeek=false }
    func stop() { stopVideo(); enabled=false; available=false; failed=false; info=nil }
}
struct MVSurface:UIViewRepresentable {
    var player:AVPlayer
    final class Surface:UIView { override class var layerClass:AnyClass { AVPlayerLayer.self }; var playerLayer:AVPlayerLayer { layer as! AVPlayerLayer } }
    func makeUIView(context:Context)->Surface { let v=Surface(); v.playerLayer.player=player; v.playerLayer.videoGravity = .resizeAspect; v.backgroundColor = .black; return v }
    func updateUIView(_ view:Surface,context:Context) { view.playerLayer.player=player }
}
