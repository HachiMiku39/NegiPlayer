import Foundation
import CoreAudio
import AudioToolbox

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var sampleRate: Double
    public var volumeWritable: Bool
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
            return .init(id: id, name: name, uid: uid, sampleRate: rate, volumeWritable: has && writable.boolValue)
        }
    }
    public static func current(_ unit: AudioUnit?) -> AudioDeviceID? {
        guard let unit else { return nil }; var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr else { return nil }
        return id
    }
}
