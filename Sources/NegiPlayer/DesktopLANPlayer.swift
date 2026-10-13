import Foundation
import AVFoundation
import Combine
import AudioCore
import LibraryDomain
import LANCore
import CoreAudio
import AudioToolbox

/// Independent network endpoint: host DSP is never part of this engine's input.
@MainActor final class DesktopLANPlayer: ObservableObject {
    @Published var track: RemoteTrack?
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var buffering = false
    @Published var outputRate = 0.0
    @Published var outputDeviceID: UInt32?
    @Published var error: String?
    @Published var preferences = PlaybackPreferences() { didSet { applyDSP(); savePreferences() } }
    var onEnded: (() -> Void)?
    var devices: [OutputDevice] { AudioDevices.list() }
    private var engine = AVAudioEngine(), node = AVAudioPlayerNode(), eq = AVAudioUnitEQ(numberOfBands: 10)
    private var level = PCMLevelControl()
    private var task: Task<Void, Never>?
    private var generation = UUID(), startFrame: Int64 = 0, scheduledEnd: Int64 = 0
    private var info: StreamInfo?, client: PinnedSession?
    private var token = ""
    private var timer: Timer?, observer: NSObjectProtocol?
    init() {
        if let data = UserDefaults.standard.data(forKey: "peer-listening-settings"), let settings = try? JSONDecoder().decode(PlaybackPreferences.self, from: data) { preferences = settings.sanitized() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in guard let self, notification.object as? AVAudioEngine === self.engine else { return }; self.pause(); self.error = "音频配置改变，请重新载入曲目" }
        }
    }
    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    var output: String { devices.first { $0.id == outputDeviceID }?.name ?? L("系统默认输出") }
    var sourceRate: Double { info?.sampleRate ?? 0 }
    var signalPath: String {
        guard let info else { return L("连接音乐主机") }
        let conversion = abs(info.sampleRate-outputRate)>1 ? " · " + L("采样率转换") : ""
        return "\(Int(info.sampleRate)) Hz PCM → \(preferences.eqEnabled ? "EQ · " : "")\(L("软件音量"))\(conversion) → \(output) · \(Int(outputRate)) Hz"
    }
    func load(_ track: RemoteTrack, client: PinnedSession, token: String) {
        stop(); guard track.playable, NegiLAN.validID(track.id) else { error = "该曲目不支持 LAN 播放"; return }
        self.track=track; self.client=client; self.token=token; error=nil; buffering=true
        let id=generation
        task=Task {
            do {
                let format=try await client.json("/v1/tracks/\(track.id)/stream-info", as:StreamInfo.self, token:token); try format.validate()
                try Task.checkCancellation(); guard generation==id else { return }
                info=format; duration=Double(format.frames)/format.sampleRate; try configure(format); playing=true; begin(at:0)
            } catch is CancellationError {} catch { if generation==id { fail(error) } }
        }
    }
    private func configure(_ info: StreamInfo) throws {
        engine.stop(); node.stop(); engine=AVAudioEngine(); node=AVAudioPlayerNode(); eq=AVAudioUnitEQ(numberOfBands:10); level=PCMLevelControl()
        if let uid=preferences.preferredDeviceUID {
            guard let chosen=devices.first(where:{$0.uid==uid}), let unit=engine.outputNode.audioUnit else { throw LANError.message("输出设备不可用") }
            var id=chosen.id
            let status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,UInt32(MemoryLayout<UInt32>.size))
            guard status==noErr, AudioDevices.current(unit)==id else { throw LANError.message("设备切换未通过回读确认") }
        }
        guard let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:info.sampleRate,channels:AVAudioChannelCount(info.channels),interleaved:false) else { throw LANError.message("无法创建音频流格式") }
        engine.attach(node); engine.attach(eq)
        let upstream=level.connect(engine:engine,from:node,format:format)
        engine.connect(upstream,to:eq,format:format); engine.connect(eq,to:engine.mainMixerNode,format:format)
        applyDSP(); try engine.start(); outputRate=engine.outputNode.outputFormat(forBus:0).sampleRate
        outputDeviceID=engine.outputNode.audioUnit.flatMap { AudioDevices.current($0) }
    }
    private func applyDSP() {
        let settings=preferences.sanitized()
        let frequencies:[Float]=[32,64,125,250,500,1000,2000,4000,8000,16000]
        for (i,band) in eq.bands.enumerated() { band.filterType = .parametric; band.frequency=min(frequencies[i],Float((info?.sampleRate ?? 44100)*0.45)); band.bandwidth=1; band.gain=settings.gains[i]; band.bypass = !settings.eqEnabled }
        eq.globalGain=settings.eqEnabled ? settings.eqPreampDB : 0
        level.apply(gainDB:LoudnessPolicy.adjustment(tags:info?.tags ?? [:],settings:settings).gainDB)
        node.volume=min(settings.volume,settings.volumeLimit)
    }
    private func begin(at seconds: Double) {
        task?.cancel(); generation=UUID(); let id=generation; node.stop()
        guard let info, let client, let trackID=track?.id else { return }
        startFrame=min(info.frames-1,max(0,Int64(max(0,seconds)*info.sampleRate))); scheduledEnd=startFrame
        position=Double(startFrame)/info.sampleRate; buffering=true
        task=Task {
            var next=startFrame
            do {
                while next<info.frames {
                    try Task.checkCancellation(); guard generation==id else { return }
                    while Double(scheduledEnd-playedFrame())/info.sampleRate>4 { try await Task.sleep(nanoseconds:100_000_000); try Task.checkCancellation() }
                    let frames=min(Int64(32768),info.frames-next), range=ByteRange(start:next*info.bytesPerFrame,count:frames*info.bytesPerFrame)
                    let (data,response)=try await client.request("/v1/tracks/\(trackID)/stream",token:token,range:range)
                    try Task.checkCancellation(); guard generation==id else { return }
                    guard response.statusCode==206, data.count==range.count, response.value(forHTTPHeaderField:"Content-Range")=="bytes \(range.start)-\(range.end)/\(info.length)" else { throw LANError.message("主机返回的音频流范围不一致") }
                    let decoded=try PCMTransport.decode(data,channels:info.channels)
                    guard let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:info.sampleRate,channels:AVAudioChannelCount(info.channels),interleaved:false),
                          let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)),let output=buffer.floatChannelData else { throw LANError.message("音频缓冲创建失败") }
                    buffer.frameLength=AVAudioFrameCount(frames)
                    for c in 0..<info.channels { decoded[c].withUnsafeBufferPointer { output[c].update(from:$0.baseAddress!,count:Int(frames)) } }
                    if node.isPlaying, let clock=clockFrame(), clock>=scheduledEnd, scheduledEnd>startFrame { node.stop(); startFrame=next }
                    next+=frames; scheduledEnd=next; let last=next==info.frames
                    node.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
                        if last { Task { @MainActor in guard let self,self.generation==id else { return }; self.position=self.duration; self.playing=false; self.buffering=false; self.onEnded?() } }
                    }
                    buffering=false; if playing && !node.isPlaying { node.play() }
                }
            } catch is CancellationError {} catch { if generation==id { fail(error) } }
        }
    }
    private func clockFrame() -> Int64? { guard let time=node.lastRenderTime, let player=node.playerTime(forNodeTime:time) else { return nil }; return startFrame+player.sampleTime }
    private func playedFrame() -> Int64 { min(scheduledEnd,max(startFrame,clockFrame() ?? startFrame)) }
    private func tick() {
        if let info, playing {
            position=min(duration,Double(playedFrame())/info.sampleRate); buffering=playedFrame()>=scheduledEnd && scheduledEnd<info.frames
            if let id=outputDeviceID, !devices.contains(where:{$0.id==id}) { pause(); error="输出设备已断开，请重新选择" }
        }
    }
    func pause() { if let info { position=Double(playedFrame())/info.sampleRate }; node.pause(); playing=false }
    func resume() { guard info != nil else { return }; do { if let uid=preferences.preferredDeviceUID { guard let selected=devices.first(where:{$0.uid==uid}),selected.id==outputDeviceID else { throw LANError.message("输出设备不可用，请重新选择设备") } }; if !engine.isRunning { try engine.start() }; playing=true; if position>=duration { begin(at:0) } else { node.play() } } catch { fail(error) } }
    func toggle() { playing ? pause() : resume() }
    func seek(_ seconds: Double) { guard seconds.isFinite, info != nil else { return }; begin(at:min(max(0,seconds),max(0,duration-0.01))) }
    func selectOutput(_ uid: String?) {
        let at=position; pause(); preferences.preferredDeviceUID=uid
        guard let info else { return }; do { try configure(info); begin(at:at) } catch { fail(error) }
    }
    func stop() { generation=UUID(); task?.cancel(); task=nil; node.stop(); engine.stop(); playing=false; buffering=false; info=nil; track=nil; position=0; duration=0 }
    private func fail(_ error: Error) { pause(); buffering=false; self.error=error.localizedDescription; task?.cancel() }
    private func savePreferences() { if let data=try? JSONEncoder().encode(preferences.sanitized()) { UserDefaults.standard.set(data,forKey:"peer-listening-settings") } }
}
