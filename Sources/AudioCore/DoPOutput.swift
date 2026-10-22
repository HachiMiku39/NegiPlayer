import Foundation
import CoreAudio
import AudioToolbox
import MediaIO
import CDoPTransport

public struct DoPDiagnostics: Codable, Sendable {
    public let deviceName: String
    public let sourceRate: Int
    public let carrierRate: Double
    public let physicalFormat: String
    public let virtualFormat: String
    public let exclusive: Bool
    public let payloadFrames: UInt64
    public let callbacks: UInt64
    public let underrunFrames: UInt64
    public let fault: Bool
    public let faultCode: Int
    public let dacDSDLockVerified: Bool
}

/// Direct HAL IOProc, with a bounded SPSC queue. No AVAudioEngine, floating point
/// mixer, software gain, effects or sample-rate converter sees the DoP payload.
public final class DoPOutput {
    public let info: DSDStreamInfo
    public let deviceID: AudioDeviceID
    public let deviceName: String
    private let reader: DSDStreamReader
    private let stream: AudioStreamID
    private let state: OpaquePointer
    private let producer=DispatchQueue(label:"local.NegiPlayer.DoP.reader",qos:.userInitiated)
    private var timer: DispatchSourceTimer?
    private var producerError: String?
    private var io: AudioDeviceIOProcID?
    private var ioStarted=false
    private var streamPrimed=false
    private var closed=false
    private var ownsHog=false
    private var mixingChanged=false
    private var oldMixing: UInt32=1
    private var baseFrame: UInt64=0
    private var listeners:[(AudioObjectID,AudioObjectPropertyAddress)]=[]
    private let oldRate: Double
    private let oldPhysical: AudioStreamBasicDescription
    private let oldVirtual: AudioStreamBasicDescription
    private var formatChanged=false
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    private static func error(_ text: String, _ status: OSStatus=0) -> NSError {
        NSError(domain:"DoP",code:Int(status),userInfo:[NSLocalizedDescriptionKey:text+(status==0 ? "" : " (\(status))")])
    }
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) throws -> T {
        var a=address(selector,scope:scope), value=initial, size=UInt32(MemoryLayout<T>.size)
        let status=withUnsafeMutablePointer(to:&value) { AudioObjectGetPropertyData(object,&a,0,nil,&size,$0) }
        guard status==noErr else { throw error("无法回读 DoP 设备属性",status) }; return value
    }
    private static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T, scope: AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) throws {
        var a=address(selector,scope:scope), v=value
        let status=withUnsafePointer(to:&v) { AudioObjectSetPropertyData(object,&a,0,nil,UInt32(MemoryLayout<T>.size),$0) }
        guard status==noErr else { throw error("无法设置 DoP 独占／整数输出格式",status) }
    }
    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T, scope: AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var a=address(selector,scope:scope), size:UInt32=0
        let status=AudioObjectGetPropertyDataSize(object,&a,0,nil,&size)
        guard status==noErr, size>0, size<=65_536, Int(size)%MemoryLayout<T>.stride==0 else { throw error("DoP 设备流属性无效",status) }
        var values=Array(repeating:zero,count:Int(size)/MemoryLayout<T>.stride)
        let result=values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object,&a,0,nil,&size,$0.baseAddress!) }
        guard result==noErr else { throw error("无法读取 DoP 设备流",result) }; return values
    }
    private static func isExact(_ f: AudioStreamBasicDescription, rate: Double) -> Bool {
        let required=kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonMixable
        let forbidden=kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsAlignedHigh | kAudioFormatFlagIsNonInterleaved
        return abs(f.mSampleRate-rate)<0.1 && f.mFormatID==kAudioFormatLinearPCM && f.mBitsPerChannel==24 && f.mChannelsPerFrame==2 && f.mBytesPerFrame==6 && f.mFramesPerPacket==1 && f.mBytesPerPacket==6 && f.mFormatFlags & required==required && f.mFormatFlags & forbidden==0
    }
    private static func formatText(_ f: AudioStreamBasicDescription) -> String { "\(Int(f.mSampleRate)) Hz · \(f.mBitsPerChannel)-bit · \(f.mChannelsPerFrame) ch · \(f.mBytesPerFrame) bytes/frame · flags \(f.mFormatFlags)" }
    private init(reader: DSDStreamReader, device: OutputDevice, stream: AudioStreamID, state: OpaquePointer, rate: Double, physical: AudioStreamBasicDescription, virtual: AudioStreamBasicDescription) {
        self.reader=reader; info=reader.info; deviceID=device.id; deviceName=device.name; self.stream=stream; self.state=state
        oldRate=rate; oldPhysical=physical; oldVirtual=virtual
    }
    public static func open(url: URL, device: OutputDevice) throws -> DoPOutput {
        guard device.isUSB else { throw error("DoP 需要明确选择支持 DoP 的 USB DAC；请先选择 WALKMAN") }
        let reader=try DSDStreamReader(url:url)
        guard device.supports(reader.info.carrierRate) else { throw error("设备不支持所需 DoP 载波采样率 \(Int(reader.info.carrierRate)) Hz") }
        let streams:[UInt32]=try array(device.id,kAudioDevicePropertyStreams,UInt32(0),scope:kAudioObjectPropertyScopeOutput)
        guard streams.count==1, let stream=streams.first else { throw error("DoP 首版只支持单流、双声道 USB DAC") }
        guard let state=negi_dop_create(131_072) else { throw error("无法分配 DoP 缓冲") }
        let output:DoPOutput
        do {
            output=try DoPOutput(reader:reader,device:device,stream:stream,state:state,
                rate:get(device.id,kAudioDevicePropertyNominalSampleRate,Double(0)),
                physical:get(stream,kAudioStreamPropertyPhysicalFormat,AudioStreamBasicDescription()),
                virtual:get(stream,kAudioStreamPropertyVirtualFormat,AudioStreamBasicDescription()))
        } catch { negi_dop_destroy(state); throw error }
        do { try output.configure(); return output } catch { output.close(); throw error }
    }
    private func configure() throws {
        let owner:pid_t=try Self.get(deviceID,kAudioDevicePropertyHogMode,pid_t(-1))
        guard owner == -1 else { throw Self.error("USB DAC 已被其他输出占用，请停止占用设备的播放器") }
        try Self.set(deviceID,kAudioDevicePropertyHogMode,getpid()); ownsHog=true
        guard try Self.get(deviceID,kAudioDevicePropertyHogMode,pid_t(-1))==getpid() else { throw Self.error("设备未确认独占，DoP 未启动") }
        var mixing=Self.address(kAudioDevicePropertySupportsMixing,scope:kAudioObjectPropertyScopeOutput)
        var writable:DarwinBoolean=false
        if AudioObjectHasProperty(deviceID,&mixing), AudioObjectIsPropertySettable(deviceID,&mixing,&writable)==noErr, writable.boolValue {
            oldMixing=try Self.get(deviceID,kAudioDevicePropertySupportsMixing,UInt32(1),scope:kAudioObjectPropertyScopeOutput)
            try Self.set(deviceID,kAudioDevicePropertySupportsMixing,UInt32(0),scope:kAudioObjectPropertyScopeOutput); mixingChanged=true
        }
        // Register the client before selecting nonmixable integer formats.
        let result=AudioDeviceCreateIOProcID(deviceID,negi_dop_io_callback(),UnsafeMutableRawPointer(state),&io)
        guard result==noErr else { throw Self.error("无法建立 DoP 整数输出回调",result) }
        let formats:[AudioStreamRangedDescription]=try Self.array(stream,kAudioStreamPropertyAvailablePhysicalFormats,AudioStreamRangedDescription())
        let rate=info.carrierRate
        let candidates=formats.filter { range in
            var f=range.mFormat; f.mSampleRate=rate
            return range.mSampleRateRange.mMinimum<=rate && rate<=range.mSampleRateRange.mMaximum && Self.isExact(f,rate:rate)
        }.sorted { ($0.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable) > ($1.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable) }
        guard var format=candidates.first?.mFormat else { throw Self.error("设备没有所需的 24 位打包整数格式，DoP 未启动") }
        format.mSampleRate=rate; formatChanged=true
        try Self.set(deviceID,kAudioDevicePropertyNominalSampleRate,rate)
        // HAL setters may return before the USB rate transition has completed.
        // Let that transition settle before requesting the nonmixable format.
        Thread.sleep(forTimeInterval:0.2)
        try Self.set(stream,kAudioStreamPropertyPhysicalFormat,format)
        var physical=AudioStreamBasicDescription()
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval:0.01)
            physical=try Self.get(stream,kAudioStreamPropertyPhysicalFormat,physical)
            if Self.isExact(physical,rate:rate) { break }
        }
        guard Self.isExact(physical,rate:rate) else { throw Self.error("物理整数格式回读不匹配，DoP 未启动") }
        // Virtual format must also be integer. A Float32 virtual format would corrupt markers.
        // The nonmixable physical format determines the IOProc format itself.
        var virtual=AudioStreamBasicDescription()
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval:0.01)
            virtual=try Self.get(stream,kAudioStreamPropertyVirtualFormat,virtual)
            if Self.isExact(virtual,rate:rate) { break }
        }
        Thread.sleep(forTimeInterval:0.1)
        physical=try Self.get(stream,kAudioStreamPropertyPhysicalFormat,physical)
        virtual=try Self.get(stream,kAudioStreamPropertyVirtualFormat,virtual)
        guard Self.isExact(physical,rate:rate) else { throw Self.error("物理整数格式未保持稳定，DoP 未启动："+Self.formatText(physical)) }
        guard Self.isExact(virtual,rate:rate), abs((AudioDevices.nominalRate(deviceID) ?? 0)-rate)<0.1 else { throw Self.error("客户端整数格式／采样率回读不匹配，DoP 未启动") }
        negi_dop_expect(state,deviceID,stream,rate)
        for (object,selector) in [(deviceID,kAudioDevicePropertyNominalSampleRate),(deviceID,kAudioDevicePropertyHogMode),(stream,kAudioStreamPropertyPhysicalFormat),(stream,kAudioStreamPropertyVirtualFormat)] {
            var a=Self.address(selector)
            let result=AudioObjectAddPropertyListener(object,&a,negi_dop_listener_callback(),UnsafeMutableRawPointer(state))
            guard result==noErr else { throw Self.error("无法监测 DoP 设备格式变化",result) }; listeners.append((object,a))
        }
        try producer.sync { try fill() }
        let source=DispatchSource.makeTimerSource(queue:producer)
        source.schedule(deadline:.now(),repeating:.milliseconds(5),leeway:.milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            do { try self.fill() } catch { self.producerError=error.localizedDescription; negi_dop_fail(self.state) }
        }
        timer=source; source.resume()
    }
    private func fill() throws {
        while negi_dop_space(state)>=4096 && negi_dop_drained(state)==0 {
            let bytes=try reader.readFrames(4096)
            if bytes.isEmpty { negi_dop_eof(state); break }
            let written=bytes.withUnsafeBytes { negi_dop_write(state,$0.bindMemory(to:UInt8.self).baseAddress!,UInt32(bytes.count/4)) }
            guard written==bytes.count/4 else { throw Self.error("DoP 缓冲写入失败") }
        }
    }
    public var position: Double { min(info.duration,Double(baseFrame+negi_dop_played(state))/info.carrierRate) }
    public var finished: Bool { negi_dop_drained(state) != 0 }
    public var failure: String? {
        guard negi_dop_fault(state) != 0 else { return nil }
        return producer.sync { producerError } ?? "输出设备的格式或独占状态改变；DoP 已停止，请重新载入"
    }
    public func start() throws {
        guard !closed else { throw Self.error("DoP 输出已关闭，请重新载入曲目") }
        if let failure { throw Self.error(failure) }
        if !ioStarted {
            if !streamPrimed {
                // WM1A can report the requested integer format before the first
                // USB stream is usable. Prime with DoP silence, then restart the
                // IOProc just as a successful seek does, without consuming music.
                negi_dop_pause(state,1)
                let result=AudioDeviceStart(deviceID,io)
                guard result==noErr else { throw Self.error("DoP 设备预热失败",result) }; ioStarted=true
                Thread.sleep(forTimeInterval:0.3)
                let stopped=AudioDeviceStop(deviceID,io)
                guard stopped==noErr else { throw Self.error("DoP 设备预热停止失败",stopped) }; ioStarted=false
                Thread.sleep(forTimeInterval:0.05)
                if let failure { throw Self.error(failure) }
                guard negi_dop_callbacks(state)>0 else { throw Self.error("DoP 预热未收到设备回调") }
                negi_dop_reset_phase(state)
                streamPrimed=true
            }
            let result=AudioDeviceStart(deviceID,io)
            guard result==noErr else { throw Self.error("DoP 设备启动失败",result) }; ioStarted=true
        }
        negi_dop_pause(state,0)
    }
    public func pause() { if !closed { negi_dop_pause(state,1) } }
    public func seek(to seconds: Double, resume: Bool) throws {
        guard !closed else { throw Self.error("DoP 输出已关闭") }
        pause()
        if ioStarted { let code=AudioDeviceStop(deviceID,io); guard code==noErr else { throw Self.error("无法暂停 DoP 设备以定位",code) }; ioStarted=false }
        try producer.sync {
            reader.seek(to:seconds); baseFrame=reader.frame; negi_dop_reset(state); try fill()
        }
        if resume { try start() }
    }
    public var diagnostics: DoPDiagnostics {
        let p=(try? Self.get(stream,kAudioStreamPropertyPhysicalFormat,AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
        let v=(try? Self.get(stream,kAudioStreamPropertyVirtualFormat,AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
        let owner=(try? Self.get(deviceID,kAudioDevicePropertyHogMode,pid_t(-1))) ?? -1
        return .init(deviceName:deviceName,sourceRate:info.sampleRate,carrierRate:info.carrierRate,
            physicalFormat:Self.formatText(p),virtualFormat:Self.formatText(v),exclusive:owner==getpid(),
            payloadFrames:negi_dop_played(state),callbacks:negi_dop_callbacks(state),underrunFrames:negi_dop_underruns(state),fault:negi_dop_fault(state) != 0,faultCode:Int(negi_dop_fault(state)),dacDSDLockVerified:false)
    }
    public func close() {
        guard !closed else { return }
        timer?.cancel(); timer=nil
        producer.sync { closed=true }
        negi_dop_pause(state,1)
        if ioStarted { _=AudioDeviceStop(deviceID,io); ioStarted=false }
        if let io { _=AudioDeviceDestroyIOProcID(deviceID,io); self.io=nil }
        for (object,var a) in listeners { _=AudioObjectRemovePropertyListener(object,&a,negi_dop_listener_callback(),UnsafeMutableRawPointer(state)) }; listeners=[]
        if ownsHog {
            if formatChanged {
                try? Self.set(stream,kAudioStreamPropertyVirtualFormat,oldVirtual)
                // Restore the physical format last. Setting a mixable virtual
                // format can otherwise make HAL select its preferred 32-bit format.
                try? Self.set(stream,kAudioStreamPropertyPhysicalFormat,oldPhysical)
                Thread.sleep(forTimeInterval:0.1)
                try? Self.set(deviceID,kAudioDevicePropertyNominalSampleRate,oldRate)
                for _ in 0..<50 {
                    if abs((AudioDevices.nominalRate(deviceID) ?? 0)-oldRate)<0.1 { break }
                    Thread.sleep(forTimeInterval:0.01)
                }
            }
            if mixingChanged { try? Self.set(deviceID,kAudioDevicePropertySupportsMixing,oldMixing,scope:kAudioObjectPropertyScopeOutput) }
            let owner=(try? Self.get(deviceID,kAudioDevicePropertyHogMode,pid_t(-1))) ?? -1
            if owner==getpid() { try? Self.set(deviceID,kAudioDevicePropertyHogMode,pid_t(-1)) }
            ownsHog=false
        }
    }
    deinit { close(); negi_dop_destroy(state) }
}

