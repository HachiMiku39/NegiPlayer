import Foundation
import AVFoundation
import Combine
import LibraryDomain
import MediaIO

@MainActor public final class PlaybackSession: ObservableObject {
    @Published public private(set) var current: MediaFile?
    @Published public private(set) var queue: [MediaFile] = []
    @Published public private(set) var isPlaying = false
    @Published public private(set) var position = 0.0
    @Published public private(set) var duration = 0.0
    @Published public private(set) var status = "尚未播放"
    @Published public private(set) var devices: [OutputDevice] = []
    @Published public private(set) var actualDeviceID: UInt32?
    @Published public private(set) var outputRate = 0.0
    @Published public private(set) var preparingOutput = false
    @Published public private(set) var isDoP = false
    @Published public private(set) var sampleRateStatus = "保持设备当前采样率"
    @Published public var followSourceSampleRate = false { didSet { persistSettings() } }
    @Published public var volume: Float = 0.5 { didSet {
        let safe = volume.isFinite ? min(volumeLimit, max(0,volume)) : 0
        if volume != safe { volume = safe }
        engine.mainMixerNode.outputVolume = isMuted ? 0 : safe; persistSettings()
    } }
    @Published public var volumeLimit: Float = 1 { didSet {
        let safe = volumeLimit.isFinite ? min(1,max(0,volumeLimit)) : 1
        if volumeLimit != safe { volumeLimit = safe }
        if volume > safe { volume = safe }; persistSettings()
    } }
    @Published public var isMuted = false { didSet {
        engine.mainMixerNode.outputVolume = isMuted ? 0 : volume
        if isDoP, isMuted { pause() }
    } }
    @Published public var loudnessMode: LoudnessMode = .off { didSet { applyLoudness(); persistSettings() } }
    @Published public var loudnessPreampDB: Float = 0 { didSet { applyLoudness(); persistSettings() } }
    @Published public var preventPeakOverload = true { didSet { applyLoudness(); persistSettings() } }
    @Published public var headroomDB: Float = 0 { didSet { applyLoudness(); persistSettings() } }
    @Published public var mediaControls = true { didSet { onMediaControlsChanged?(mediaControls); persistSettings() } }
    @Published public private(set) var loudness = LoudnessAdjustment(gainDB: 0, status: "响度统一已关闭", peakLimited: false)
    @Published public private(set) var presetName = "自定义"
    @Published public var repeatQueue = false
    @Published public var shuffle = false
    @Published public private(set) var eqEnabled = false
    @Published public private(set) var gains: [Float] = Array(repeating: 0, count: 10)
    @Published public var preamp: Float = -6 { didSet { eq.globalGain = preamp.isFinite ? min(0,max(-24,preamp)) : -6; presetName = "自定义"; applyLoudness(); persistSettings() } }
    public var onMediaControlsChanged: ((Bool) -> Void)?
    public var onPreferencesChanged: ((PlaybackPreferences) -> Void)?
    private var preferredDeviceUID: String?
    public var onTrackChanged: ((MediaFile) -> Void)?
    public let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let gainUnit = AVAudioUnitEQ(numberOfBands: 1)
    private var file: AVAudioFile?
    private var dop: DoPOutput?
    private var dopDrainedAt: Double?
    public var dopDiagnostics: DoPDiagnostics? { dop?.diagnostics }
    private var baseFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var deviceObserver: NSObjectProtocol?
    private var anchor = PlaybackAnchor(mediaSeconds: 0, eventUptime: 0, running: false)
    private var lastDeviceCheck = 0.0
    private var expectedRateChange: (device: UInt32, rate: Double, deadline: Double)?
    public init(preferences: PlaybackPreferences = .init()) {
        let s = preferences.sanitized()
        volumeLimit = s.volumeLimit; volume = s.volume; loudnessMode = s.loudnessMode
        loudnessPreampDB = s.loudnessPreampDB; preventPeakOverload = s.preventPeakOverload; headroomDB = s.headroomDB
        eqEnabled = s.eqEnabled; gains = s.gains; preamp = s.eqPreampDB; presetName = s.presetName
        mediaControls = s.mediaControls; preferredDeviceUID = s.preferredDeviceUID
        followSourceSampleRate = s.followSourceSampleRate ?? false
        engine.attach(player); engine.attach(eq); engine.attach(gainUnit)
        gainUnit.bands[0].bypass = true
        for (i, frequency) in frequencies.enumerated() {
            eq.bands[i].filterType = .parametric; eq.bands[i].frequency = frequency
            eq.bands[i].bandwidth = 1; eq.bands[i].bypass = false; eq.bands[i].gain = gains[i]
        }
        eq.globalGain = preamp
        engine.mainMixerNode.outputVolume = volume
        applyLoudness()
        devices = AudioDevices.list()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
        // Hardware topology is checked separately, because some removals do not immediately reconfigure the graph.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    public var latency: Double { isDoP ? 0 : engine.outputNode.presentationLatency }
    public var pathDescription: String {
        guard let current else { return "选择本地音乐开始播放" }
        if isDoP { return "\(current.codec) · DSD\(Int(current.sampleRate/44_100)) → DoP · 24-bit integer / \(Int(outputRate)) Hz → \(dop?.deviceName ?? "USB DAC")（独占；设备 DSD 锁定待确认）" }
        if current.isDSD { return "\(current.codec) · DoP 输出已停止；重新载入曲目可再次播放" }
        let device = devices.first { $0.id == actualDeviceID }?.name ?? "设备待确认"
        let rate = current.sampleRate > 0 ? " \(Int(current.sampleRate)) Hz" : ""
        let conversion = outputRate > 0 && abs(current.sampleRate-outputRate) > 1 ? " · 采样率转换" : ""
        let gain = abs(loudness.gainDB) > 0.0001 ? String(format: " · 增益 %+.1f dB", loudness.gainDB) : ""
        return "\(current.codec)\(rate) → PCM\(gain)\(eqEnabled ? " · EQ" : "") · \(isMuted ? "静音" : "软件音量")\(conversion) → \(device) · \(Int(outputRate)) Hz（系统混音）"
    }
    public var preferences: PlaybackPreferences {
        var s = PlaybackPreferences(); s.volume = volume; s.volumeLimit = volumeLimit; s.loudnessMode = loudnessMode
        s.loudnessPreampDB = loudnessPreampDB; s.preventPeakOverload = preventPeakOverload; s.headroomDB = headroomDB
        s.eqEnabled = eqEnabled; s.gains = gains; s.eqPreampDB = preamp; s.presetName = presetName
        s.mediaControls = mediaControls; s.preferredDeviceUID = preferredDeviceUID; s.followSourceSampleRate = followSourceSampleRate; return s.sanitized()
    }
    private func persistSettings() { onPreferencesChanged?(preferences) }
    private func applyLoudness() {
        loudness = LoudnessPolicy.adjustment(tags: current?.tags ?? [:], settings: preferences)
        gainUnit.globalGain = loudness.gainDB; gainUnit.bypass = abs(loudness.gainDB) < 0.0001
    }
    public var confirmedOutputFormat: String {
        if let dop { return dop.diagnostics.physicalFormat+" · 物理／客户端格式均已回读 · 独占" }
        guard current != nil, outputRate > 0 else { return "播放后回读输出格式" }
        let f = engine.outputNode.outputFormat(forBus: 0)
        return "\(Int(f.sampleRate)) Hz · \(f.channelCount) 声道 · \(f.streamDescription.pointee.mBitsPerChannel) 位客户端格式"
    }
    public func refreshDevices() { devices = AudioDevices.list() }
    public func updateAudioIdentity(mediaID: String, identity: String) {
        if current?.id == mediaID { current?.audioIdentity = identity }
        for i in queue.indices where queue[i].id == mediaID { queue[i].audioIdentity = identity }
    }
    public func setQueue(_ files: [MediaFile], startingAt media: MediaFile, url: URL) async throws {
        queue = files; try await load(media, url: url, autoplay: true)
    }
    public func enqueue(_ media: MediaFile, next: Bool) { queue = QueuePlan.inserting(media, into: queue, currentID: current?.id, next: next) }
    public func removeQueued(_ mediaID: String) { if mediaID != current?.id { queue.removeAll { $0.id == mediaID } } }
    public func clearUpcoming() { queue = current.map { [$0] } ?? [] }
    public func moveQueued(_ mediaID: String, by delta: Int) {
        guard let index = queue.firstIndex(where: { $0.id == mediaID }), queue.indices.contains(index+delta) else { return }
        queue.swapAt(index,index+delta)
    }
    public func load(_ media: MediaFile, url: URL, autoplay: Bool) async throws {
        guard media.available else { throw NSError(domain: "Playback", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件暂不可用，请重新扫描或授权目录"]) }
        guard !media.isDiscImage else { throw NSError(domain: "Playback", code: 5, userInfo: [NSLocalizedDescriptionKey: media.issue ?? "镜像播放尚未接通"]) }
        if media.isDSD { try loadDoP(media,url:url,autoplay:autoplay); return }
        let audio = try AVAudioFile(forReading: url)
        closeDoP()
        generation += 1; player.stop(); engine.stop(); freeze(at: 0)
        let version = generation
        preparingOutput = true
        defer { if generation == version { preparingOutput = false } }
        file = nil; current = media; baseFrame = 0; position = 0; outputRate = 0
        applyLoudness()
        duration = Double(audio.length)/audio.processingFormat.sampleRate
        refreshDevices()
        if let uid = preferredDeviceUID {
            refreshDevices()
            guard let device = devices.first(where: { $0.uid == uid }) else {
                status = "记住的输出设备离线；请选择设备后重新载入曲目"
                throw NSError(domain: "Playback", code: 4, userInfo: [NSLocalizedDescriptionKey: status])
            }
            if AudioDevices.current(engine.outputNode.audioUnit) != device.id { try chooseDevice(device.id) }
        }
        sampleRateStatus = "保持设备当前采样率"
        if followSourceSampleRate {
            guard let uid = preferredDeviceUID, let device = devices.first(where: { $0.uid == uid }) else {
                throw NSError(domain:"Playback",code:6,userInfo:[NSLocalizedDescriptionKey:"跟随源采样率需要先明确选择输出设备"])
            }
            let rate = audio.processingFormat.sampleRate
            if !device.supports(rate) || !device.sampleRateWritable {
                sampleRateStatus = "设备不支持源采样率，保留当前格式并进行采样率转换"
            } else if abs((AudioDevices.nominalRate(device.id) ?? 0)-rate) > 1 {
                status = "静音切换采样率…"
                expectedRateChange = (device.id, rate, ProcessInfo.processInfo.systemUptime+4)
                try AudioDevices.requestRate(rate,device:device)
                var confirmed = false
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds:50_000_000)
                    guard generation == version else { throw CancellationError() }
                    if let actual = AudioDevices.nominalRate(device.id), abs(actual-rate) < 1 { confirmed = true; break }
                }
                guard confirmed else { throw NSError(domain:"Playback",code:7,userInfo:[NSLocalizedDescriptionKey:"采样率切换未通过回读确认，播放保持暂停"]) }
                // Let the stopped engine consume its configuration notification before reconnecting.
                try await Task.sleep(nanoseconds:100_000_000)
                sampleRateStatus = "已跟随源采样率，设备回读确认"
            } else { sampleRateStatus = "已跟随源采样率，设备回读确认" }
        }
        guard generation == version else { throw CancellationError() }
        engine.reset(); file = audio
        configureGraph(audio.processingFormat); schedule(from: 0); refreshDevices()
        preparingOutput = false
        if autoplay { try start() } else { freeze(at: 0); status = "已载入" }
        onTrackChanged?(media)
    }
    private func closeDoP() { if dop != nil { dop?.close(); outputRate=0 }; dop=nil; isDoP=false; dopDrainedAt=nil }
    public func stop() { player.stop(); engine.stop(); closeDoP(); file=nil; freeze(at:position); status="已停止" }
    private func loadDoP(_ media: MediaFile, url: URL, autoplay: Bool) throws {
        refreshDevices()
        guard let uid=preferredDeviceUID, let device=devices.first(where:{$0.uid==uid}), device.isUSB else {
            throw NSError(domain:"Playback",code:8,userInfo:[NSLocalizedDescriptionKey:"请先在输出设置中选择支持 DoP 的 USB DAC（WALKMAN）"])
        }
        _ = try DSDStreamReader(url:url)
        generation+=1; preparingOutput=true
        defer { preparingOutput=false }
        player.stop(); engine.stop(); file=nil; closeDoP(); freeze(at:0)
        current=media; position=0; outputRate=0
        do {
            let output=try DoPOutput.open(url:url,device:device)
            dop=output; isDoP=true; duration=output.info.duration; actualDeviceID=device.id; outputRate=output.info.carrierRate
            sampleRateStatus="DoP 载波采样率与物理／客户端整数格式均已回读确认"
            status="DoP 已载入；请使用 DAC 本机音量，软件音量与 DSP 已旁路"
            if autoplay && !isMuted { try output.start(); isPlaying=true; status="播放中 · DoP（设备 DSD 锁定待确认）" }
            anchor = .init(mediaSeconds:0,eventUptime:ProcessInfo.processInfo.systemUptime,running:isPlaying)
            refreshDevices(); onTrackChanged?(media)
        } catch { closeDoP(); status=error.localizedDescription; throw error }
    }
    private func configureGraph(_ format: AVAudioFormat) {
        engine.disconnectNodeOutput(player); engine.disconnectNodeOutput(eq); engine.disconnectNodeOutput(gainUnit)
        engine.connect(player, to: gainUnit, format: format)
        if eqEnabled { engine.connect(gainUnit, to: eq, format: format); engine.connect(eq, to: engine.mainMixerNode, format: format) }
        else { engine.connect(gainUnit, to: engine.mainMixerNode, format: format) }
    }
    private func schedule(from frame: AVAudioFramePosition) {
        guard let file, frame < file.length else { return }
        let version = generation
        player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(min(Int64(UInt32.max), file.length-frame)), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == version else { return }
                self.position = self.duration; self.freeze(at: self.duration); self.status = "播放完成"
                self.advance()
            }
        }
    }
    public func start() throws {
        if let dop {
            guard !preparingOutput else { return }
            if position>=duration { try dop.seek(to:0,resume:false); position=0; dopDrainedAt=nil }
            if isMuted { isMuted=false }
            try dop.start(); isPlaying=true; status="播放中 · DoP（设备 DSD 锁定待确认）"; return
        }
        if current?.isDSD == true { throw NSError(domain:"Playback",code:9,userInfo:[NSLocalizedDescriptionKey:"DoP 输出已关闭，请重新载入曲目"]) }
        guard file != nil, !preparingOutput else { return }
        if position >= duration { try seek(to: 0) }
        if !engine.isRunning { try engine.start() }
        player.play(); isPlaying = true; status = "播放中 · PCM 兼容输出"
        actualDeviceID = AudioDevices.current(engine.outputNode.audioUnit)
        outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        anchor = .init(mediaSeconds: position, eventUptime: ProcessInfo.processInfo.systemUptime, running: true)
    }
    public func pause() {
        if let dop { dop.pause(); position=dop.position; freeze(at:position); status="DoP 已暂停 · 发送 DSD 静音"; return }
        refresh(); player.pause(); freeze(at: position); status = "已暂停"
    }
    private func freeze(at time: Double) { isPlaying = false; anchor = .init(mediaSeconds: time, eventUptime: ProcessInfo.processInfo.systemUptime, running: false) }
    public func toggle() throws { if isPlaying { pause() } else { try start() } }
    public func seek(to time: Double) throws {
        if let dop {
            let playing=isPlaying
            try dop.seek(to:time,resume:playing); position=dop.position; dopDrainedAt=nil
            anchor = .init(mediaSeconds:position,eventUptime:ProcessInfo.processInfo.systemUptime,running:playing); return
        }
        guard let file else { return }; let playing = isPlaying
        generation += 1; player.stop()
        let target = min(max(time, 0), duration)
        baseFrame = min(file.length, AVAudioFramePosition(target*file.processingFormat.sampleRate))
        position = target; freeze(at: target); schedule(from: baseFrame)
        if playing && target < duration { try start() }
    }
    /// Event uptime is NSEvent.timestamp. Anchored to the node's rendering clock, with output latency separated.
    public func mediaTime(forEventUptime uptime: Double) -> Double {
        refresh(); return min(duration, max(0, anchor.mediaTime(at: uptime)))
    }
    public func refresh() {
        if let dop {
            position=dop.position
            anchor = .init(mediaSeconds:position,eventUptime:ProcessInfo.processInfo.systemUptime,running:isPlaying)
            let uptime=ProcessInfo.processInfo.systemUptime
            if let failure=dop.failure {
                closeDoP(); freeze(at:position); status=failure; refreshDevices(); return
            }
            if uptime-lastDeviceCheck>1 {
                lastDeviceCheck=uptime; refreshDevices()
                if !devices.contains(where:{$0.id==dop.deviceID}) { closeDoP(); freeze(at:position); status="USB DAC 已断开；请重新选择设备并载入"; return }
            }
            if isPlaying && dop.finished {
                if let end=dopDrainedAt, uptime-end>=0.15 {
                    position=duration; closeDoP(); freeze(at:duration); status="DoP 播放完成"; advance()
                } else if dopDrainedAt==nil { dopDrainedAt=uptime }
            }
            return
        }
        if isPlaying, let file, let render = player.lastRenderTime, let played = player.playerTime(forNodeTime: render) {
            let rendered = Double(baseFrame)/file.processingFormat.sampleRate + Double(played.sampleTime)/played.sampleRate
            let present = min(duration, max(Double(baseFrame)/file.processingFormat.sampleRate, rendered-latency))
            position = present
            let hostSeconds = AVAudioTime.seconds(forHostTime: render.hostTime)
            anchor = .init(mediaSeconds: present, eventUptime: hostSeconds, running: true)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if let id = actualDeviceID, isPlaying, uptime-lastDeviceCheck > 1 {
            lastDeviceCheck = uptime
            // No fallback to another device while the selected device is gone.
            let latest = AudioDevices.list()
            if !latest.contains(where: { $0.id == id }) {
                player.stop(); engine.stop(); generation += 1; freeze(at: position)
                status = "输出设备已断开；请重新选择设备并载入曲目"; file = nil
            }
            if devices != latest { devices = latest }
        }
    }
    public func chooseDevice(_ id: UInt32) throws {
        pause(); closeDoP(); engine.stop(); refreshDevices()
        guard devices.contains(where: { $0.id == id }), let unit = engine.outputNode.audioUnit else { throw NSError(domain: "Playback", code: 3, userInfo: [NSLocalizedDescriptionKey: "输出设备不可用"]) }
        var device = id
        let statusCode = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<UInt32>.size))
        guard statusCode == noErr, AudioDevices.current(unit) == id else { throw NSError(domain: "Playback", code: Int(statusCode), userInfo: [NSLocalizedDescriptionKey: "设备切换未通过回读确认"]) }
        actualDeviceID = id; outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        preferredDeviceUID = devices.first(where: { $0.id == id })?.uid; persistSettings()
        status = "设备已切换，播放已暂停"
    }
    public func setEQ(_ enabled: Bool) throws {
        if isDoP { return }
        let playing = isPlaying; pause(); engine.stop(); eqEnabled = enabled
        applyLoudness()
        if let file { configureGraph(file.processingFormat); try seek(to: position); if playing { try start() } }
        persistSettings()
    }
    public func setGain(_ value: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        let safe = value.isFinite ? min(12,max(-12,value)) : 0
        gains[band] = safe; eq.bands[band].gain = safe; presetName = "自定义"; applyLoudness(); persistSettings()
    }
    public func applyPreset(_ preset: EQPreset) {
        // Set attenuation before boosted bands; preset selection does not enable EQ.
        preamp = min(preamp,preset.preampDB)
        for i in 0..<10 { setGain(preset.gains[i], band: i) }
        preamp = preset.preampDB; presetName = preset.name; persistSettings()
    }
    public func previous() {
        if position > 3 { try? seek(to: 0); return }
        guard let current, let index = queue.firstIndex(where: { $0.id == current.id }), index > 0 else { return }
        onNext?(queue[index-1])
    }
    public var nextItem: MediaFile? {
        guard let current, !queue.isEmpty else { return nil }
        if shuffle { return queue.filter { $0.id != current.id }.randomElement() ?? (repeatQueue ? current : nil) }
        guard let index = queue.firstIndex(where: { $0.id == current.id }) else { return nil }
        return index+1 < queue.count ? queue[index+1] : (repeatQueue ? queue.first : nil)
    }
    public var onNext: ((MediaFile) -> Void)?
    public func advance() { if let next = nextItem { onNext?(next) } }
    private func handleConfigurationChange() {
        if preparingOutput { return }
        if isDoP || current?.isDSD == true { return }
        if let expected = expectedRateChange,
           ProcessInfo.processInfo.systemUptime < expected.deadline,
           AudioDevices.current(engine.outputNode.audioUnit) == expected.device,
           let rate = AudioDevices.nominalRate(expected.device), abs(rate-expected.rate) < 1,
           abs(engine.outputNode.outputFormat(forBus:0).sampleRate-expected.rate) < 1 {
            refreshDevices(); return
        }
        guard current != nil else { return }
        player.stop(); engine.stop(); generation += 1; freeze(at: position); file = nil
        status = "音频配置改变；已停止输出，请重新载入曲目"
        refreshDevices()
    }
}
