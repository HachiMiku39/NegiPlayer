import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine
#if canImport(LANCore)
import LANCore
#endif

@MainActor final class MobilePlayer:ObservableObject {
    @Published var track:RemoteTrack?
    @Published var position=0.0
    @Published var duration=0.0
    @Published var playing=false
    @Published var buffering=false
    @Published var output="尚未启用音频"
    @Published var outputRate=0.0
    @Published var isUSB=false
    @Published var error:String?
    @Published var preferences=PlaybackPreferences() { didSet { applyDSP(); savePreferences() } }
    @Published var muted=false { didSet { applyDSP() } }
    @Published var preferredRate=0.0
    var onEnded:(()->Void)?
    var onProgress:((Double,Bool)->Void)?
    private var engine=AVAudioEngine(), node=AVAudioPlayerNode(), eq=AVAudioUnitEQ(numberOfBands:10)
    private var level=PCMLevelControl()
    private var streamTask:Task<Void,Never>?
    private var generation=UUID()
    private var startFrame:Int64=0, scheduledEnd:Int64=0
    private var info:StreamInfo?
    private var client:PinnedSession?
    private var token=""
    private var timer:Timer?
    private var observers:[NSObjectProtocol]=[]
    private var configuredRoute=""
    private var remoteTargets:[(MPRemoteCommand,Any)]=[]
    init() {
        if let data=UserDefaults.standard.data(forKey:"listening-settings"), let p=try? JSONDecoder().decode(PlaybackPreferences.self,from:data) { preferences=p.sanitized() }
        preferredRate=UserDefaults.standard.double(forKey:"preferred-output-rate")
        timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak self] n in Task { @MainActor in self?.routeChanged(n) } })
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] n in Task { @MainActor in
            guard let self else { return }; if (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)==AVAudioSession.InterruptionType.began.rawValue { self.pause(); self.output="音频被系统中断，点击播放恢复" }
        } })
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.mediaServicesWereResetNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.resetAfterMediaService() } })
        let center=MPRemoteCommandCenter.shared()
        remoteTargets.append((center.playCommand,center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }))
        remoteTargets.append((center.pauseCommand,center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }))
        remoteTargets.append((center.changePlaybackPositionCommand,center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e=event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }; Task { @MainActor in self?.seek(e.positionTime) }; return .success
        }))
    }
    func setNextPrevious(next:@escaping()->Void,previous:@escaping()->Void) {
        let center=MPRemoteCommandCenter.shared()
        remoteTargets.append((center.nextTrackCommand,center.nextTrackCommand.addTarget { _ in Task { @MainActor in next() }; return .success }))
        remoteTargets.append((center.previousTrackCommand,center.previousTrackCommand.addTarget { _ in Task { @MainActor in previous() }; return .success }))
    }
    func load(_ track:RemoteTrack,client:PinnedSession,token:String) {
        stop(); self.track=track; self.client=client; self.token=token; duration=track.duration; error=nil; buffering=true
        let id=generation
        streamTask=Task {
            do {
                let format=try await client.json("/v1/tracks/\(track.id)/stream-info",as:StreamInfo.self,token:token); try format.validate()
                try Task.checkCancellation(); guard generation==id else { return }; info=format; duration=Double(format.frames)/format.sampleRate
                try configure(format); playing=true; begin(at:0)
            } catch is CancellationError {} catch { if generation==id { fail(error) } }
        }
    }
    private func configure(_ info:StreamInfo) throws {
        let session=AVAudioSession.sharedInstance()
        try session.setCategory(.playback,mode:.default,options:[])
        try session.setPreferredSampleRate(preferredRate>0 ? preferredRate : info.sampleRate)
        try session.setActive(true)
        engine.stop(); node.stop(); engine=AVAudioEngine(); node=AVAudioPlayerNode(); eq=AVAudioUnitEQ(numberOfBands:10); level=PCMLevelControl()
        guard let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:info.sampleRate,channels:AVAudioChannelCount(info.channels),interleaved:false) else { throw LANError.message("无法创建 iOS 音频格式") }
        engine.attach(node); engine.attach(eq)
        let upstream=level.connect(engine:engine,from:node,format:format)
        engine.connect(upstream,to:eq,format:format); engine.connect(eq,to:engine.mainMixerNode,format:format)
        applyDSP(); try engine.start(); updateRoute(); configuredRoute=routeSignature()
    }
    private func applyDSP() {
        let settings=preferences.sanitized(), f:[Float]=[32,64,125,250,500,1000,2000,4000,8000,16000]
        for (i,band) in eq.bands.enumerated() { band.filterType = .parametric; band.frequency=min(f[i],Float((info?.sampleRate ?? 44100)*0.45)); band.bandwidth=1; band.gain=settings.gains[i]; band.bypass = !settings.eqEnabled }
        eq.globalGain=settings.eqEnabled ? settings.eqPreampDB : 0
        let gain=LoudnessPolicy.adjustment(tags:info?.tags ?? [:],settings:settings).gainDB
        // Mixing volume is limited to 0...1. Apply metadata gain in linear EQ stages, each within the native -96...24 dB range.
        level.apply(gainDB:gain)
        node.volume=muted ? 0 : min(settings.volume,settings.volumeLimit)
    }
    private func begin(at seconds:Double) {
        streamTask?.cancel(); generation=UUID(); let id=generation; node.stop()
        guard let info, let client, let trackID=track?.id else { return }
        startFrame=min(info.frames-1,max(0,Int64(max(0,seconds)*info.sampleRate))); scheduledEnd=startFrame; position=Double(startFrame)/info.sampleRate; buffering=true
        streamTask=Task {
            var next=startFrame
            do {
                while next<info.frames {
                    try Task.checkCancellation(); guard generation==id else { return }
                    // Bounded prefetch: at most 4 seconds in the player node, plus one response.
                    while Double(scheduledEnd-playedFrame())/info.sampleRate>4 {
                        try await Task.sleep(nanoseconds:100_000_000); try Task.checkCancellation()
                    }
                    let frames=min(Int64(32768),info.frames-next), range=ByteRange(start:next*info.bytesPerFrame,count:frames*info.bytesPerFrame)
                    let (data,response)=try await client.request("/v1/tracks/\(trackID)/stream",token:token,range:range)
                    try Task.checkCancellation(); guard generation==id else { return }
                    guard response.statusCode==206, data.count==range.count,
                          response.value(forHTTPHeaderField:"Content-Range")=="bytes \(range.start)-\(range.end)/\(info.length)" else { throw LANError.message("Mac 返回的音频流范围不一致") }
                    let decoded=try PCMTransport.decode(data,channels:info.channels)
                    guard let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:info.sampleRate,channels:AVAudioChannelCount(info.channels),interleaved:false),
                          let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)), let out=buffer.floatChannelData else { throw LANError.message("音频缓冲创建失败") }
                    buffer.frameLength=AVAudioFrameCount(frames)
                    for c in 0..<info.channels { decoded[c].withUnsafeBufferPointer { ptr in out[c].update(from:ptr.baseAddress!,count:Int(frames)) } }
                    // Re-anchor after a network underrun so the lyric clock never runs through silence.
                    if node.isPlaying, let clock=clockFrame(), clock>=scheduledEnd, scheduledEnd>startFrame { node.stop(); startFrame=next }
                    next+=frames; scheduledEnd=next; let last=next==info.frames
                    node.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
                        if last { Task { @MainActor in guard let self, self.generation==id else { return }; self.position=self.duration; self.playing=false; self.buffering=false; self.updateNowPlaying(); self.onProgress?(self.position,false); self.onEnded?() } }
                    }
                    buffering=false; if playing && !node.isPlaying { node.play() }
                }
            } catch is CancellationError {} catch { if generation==id { fail(error) } }
        }
        updateNowPlaying()
    }
    private func clockFrame() -> Int64? { guard let time=node.lastRenderTime, let player=node.playerTime(forNodeTime:time) else { return nil }; return startFrame+player.sampleTime }
    private func playedFrame() -> Int64 { min(scheduledEnd,max(startFrame,clockFrame() ?? startFrame)) }
    private func tick() {
        if let info, playing { position=min(duration,Double(playedFrame())/info.sampleRate); if playedFrame()>=scheduledEnd, scheduledEnd<info.frames { buffering=true } }
        onProgress?(position,playing && !buffering); updateNowPlaying()
    }
    func pause() { if info != nil { position=Double(playedFrame())/info!.sampleRate }; node.pause(); playing=false; updateNowPlaying(); onProgress?(position,false) }
    func resume() {
        guard info != nil else { return }; if position>=duration { playing=true; begin(at:0); return }
        do { try AVAudioSession.sharedInstance().setActive(true); if !engine.isRunning { try engine.start() }; playing=true; node.play(); updateNowPlaying() } catch { fail(error) }
    }
    func toggle() { playing ? pause() : resume() }
    func seek(_ value:Double) { guard value.isFinite, info != nil else { return }; begin(at:min(max(0,value),max(0,duration-0.01))); onProgress?(position,false) }
    func stop() { generation=UUID(); streamTask?.cancel(); streamTask=nil; node.stop(); engine.stop(); playing=false; buffering=false; info=nil; track=nil; position=0; duration=0; MPNowPlayingInfoCenter.default().nowPlayingInfo=nil }
    private func fail(_ error:Error) { pause(); buffering=false; self.error=error.localizedDescription; streamTask?.cancel() }
    func updateRoute() {
        let session=AVAudioSession.sharedInstance(); output=session.currentRoute.outputs.map(\.portName).joined(separator:" · "); outputRate=session.sampleRate; isUSB=session.currentRoute.outputs.contains{$0.portType == .usbAudio}
    }
    private func routeSignature() -> String {
        let s=AVAudioSession.sharedInstance(); return s.currentRoute.outputs.map{$0.uid}.joined(separator:"|")+"@"+String(s.sampleRate)
    }
    private func routeChanged(_ notification:Notification) {
        let wasUSB=isUSB, wasPlaying=playing; let at=position; updateRoute()
        let reason=notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if reason==AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause(); if wasUSB { error="USB 音频设备已断开，已暂停以避免转到扬声器" }; return }
        guard let info, routeSignature() != configuredRoute else { return }
        do { try configure(info); playing=wasPlaying; begin(at:at) } catch { fail(error) }
    }
    func changePreferredRate(_ value:Double) {
        preferredRate=value; UserDefaults.standard.set(value,forKey:"preferred-output-rate")
        guard let info else { return }; let at=position, wasPlaying=playing
        do { try configure(info); playing=wasPlaying; begin(at:at) } catch { fail(error) }
    }
    private func resetAfterMediaService() { let at=position; guard let info else { return }; do { try configure(info); playing=false; begin(at:at) } catch { fail(error) } }
    private func savePreferences() { if let data=try? JSONEncoder().encode(preferences.sanitized()) { UserDefaults.standard.set(data,forKey:"listening-settings") } }
    private func updateNowPlaying() {
        guard let track else { return }; var data:[String:Any]=[MPMediaItemPropertyTitle:track.title,MPMediaItemPropertyArtist:track.artist,MPMediaItemPropertyAlbumTitle:track.album,MPMediaItemPropertyPlaybackDuration:duration,MPNowPlayingInfoPropertyElapsedPlaybackTime:position,MPNowPlayingInfoPropertyPlaybackRate:playing && !buffering ? 1.0 : 0.0]
        if let artwork=MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] { data[MPMediaItemPropertyArtwork]=artwork }; MPNowPlayingInfoCenter.default().nowPlayingInfo=data
    }
    func setArtwork(_ image:UIImage?) { guard let image, var info=MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }; info[MPMediaItemPropertyArtwork]=MPMediaItemArtwork(boundsSize:image.size){_ in image}; MPNowPlayingInfoCenter.default().nowPlayingInfo=info }
}
