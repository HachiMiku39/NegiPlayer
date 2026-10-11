import Foundation
import CoreAudio
import AudioToolbox

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var sampleRate: Double
    public var volumeWritable: Bool
    public var isUSB: Bool
    public var sampleRateWritable: Bool
    public var supportedRates: [ClosedRange<Double>]
    public var physicalFormat: String
    public func supports(_ rate: Double) -> Bool {
        rate.isFinite && supportedRates.contains { $0.contains(rate) }
    }
    public var rateDescription: String {
        supportedRates.map { $0.lowerBound == $0.upperBound ? String(Int($0.lowerBound)) : "\(Int($0.lowerBound))–\(Int($0.upperBound))" }.joined(separator: ", ")
    }
}
public enum AudioDevices {
    public static func list() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size)/MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var nameRef: Unmanaged<CFString>?; var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = withUnsafeMutablePointer(to: &nameRef) { AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, $0) }
            let name = nameStatus == noErr ? nameRef?.takeRetainedValue() as String? ?? "未知设备" : "未知设备"
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uidRef: Unmanaged<CFString>?; var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uidRef) { AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, $0) }
            let uid = uidStatus == noErr ? uidRef?.takeRetainedValue() as String? ?? "" : ""
            var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var rate: Double = 0; var rateSize = UInt32(MemoryLayout<Double>.size)
            _ = AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate)
            var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var writable: DarwinBoolean = false
            let has = AudioObjectHasProperty(id, &volumeAddress)
            if has { _ = AudioObjectIsPropertySettable(id, &volumeAddress, &writable) }
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            var rateWritable: DarwinBoolean = false
            _ = AudioObjectIsPropertySettable(id, &rateAddress, &rateWritable)
            var rangesAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var rangesSize: UInt32 = 0; var ranges: [ClosedRange<Double>] = []
            if AudioObjectGetPropertyDataSize(id, &rangesAddress, 0, nil, &rangesSize) == noErr, rangesSize > 0, rangesSize <= 65536 {
                var values = [AudioValueRange](repeating: .init(mMinimum: 0,mMaximum: 0), count: Int(rangesSize)/MemoryLayout<AudioValueRange>.size)
                if AudioObjectGetPropertyData(id, &rangesAddress, 0, nil, &rangesSize, &values) == noErr {
                    ranges = values.filter { $0.mMinimum.isFinite && $0.mMaximum.isFinite && $0.mMinimum > 0 && $0.mMaximum >= $0.mMinimum && $0.mMaximum <= 3_072_000 }.map { $0.mMinimum...$0.mMaximum }.sorted { $0.lowerBound < $1.lowerBound }
                }
            }
            var streams = [AudioStreamID](repeating: 0, count: Int(streamSize)/MemoryLayout<AudioStreamID>.size)
            var physical = ""
            if AudioObjectGetPropertyData(id, &streamAddress, 0, nil, &streamSize, &streams) == noErr, let stream = streams.first {
                var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var format = AudioStreamBasicDescription(); var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                if AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr {
                    physical = "\(Int(format.mSampleRate)) Hz · \(format.mChannelsPerFrame) ch · \(format.mBitsPerChannel) bit " + (format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "Float" : "PCM")
                }
            }
            return .init(id: id, name: name, uid: uid, sampleRate: rate, volumeWritable: has && writable.boolValue, isUSB: transport == kAudioDeviceTransportTypeUSB, sampleRateWritable: rateWritable.boolValue, supportedRates: ranges, physicalFormat: physical)
        }
    }
    public static func current(_ unit: AudioUnit?) -> AudioDeviceID? {
        guard let unit else { return nil }; var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr else { return nil }
        return id
    }
    public static func nominalRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0, size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return nil }; return rate
    }
    /// Changes only an explicitly selected device. The caller stops output before requesting a rate.
    public static func requestRate(_ rate: Double, device: OutputDevice) throws {
        guard device.sampleRateWritable, device.supports(rate) else { throw NSError(domain:"AudioDevice",code:1,userInfo:[NSLocalizedDescriptionKey:"设备不支持源采样率，保留当前格式并进行采样率转换"]) }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let status = AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { throw NSError(domain:"AudioDevice",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"采样率切换失败，播放保持暂停"]) }
    }
}
