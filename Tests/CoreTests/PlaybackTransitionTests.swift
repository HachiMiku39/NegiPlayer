import XCTest
import AVFoundation
import CoreAudio
import AudioCore
import LibraryDomain

final class PlaybackTransitionTests: XCTestCase {
    /// Opt in only with the connected WALKMAN; generated fixtures contain silence.
    @MainActor func testWalkmanPCMDoPRoundTrips() async throws {
        guard ProcessInfo.processInfo.environment["NEGI_TEST_WALKMAN"] == "1" else {
            throw XCTSkip("Set NEGI_TEST_WALKMAN=1 with a WALKMAN USB DAC connected")
        }
        let device = try XCTUnwrap(AudioDevices.list().first { $0.name == "WALKMAN" && $0.isUSB })
        let initialRate = try XCTUnwrap(AudioDevices.nominalRate(device.id))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pcmURL = directory.appendingPathComponent("silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 12))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        try autoreleasepool {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let audio = try AVAudioFile(forWriting: pcmURL, settings: settings)
            try audio.write(from: buffer)
        }
        let pcm = MediaFile(rootID: "fixture", relativePath: "silence.wav", title: "PCM silence", codec: "WAV", sampleRate: 48_000, channels: 2)
        let session = PlaybackSession()
        defer { session.stop(); try? AudioDevices.requestRate(initialRate, device: device) }
        try AudioDevices.requestRate(44_100, device: device)
        try session.chooseDevice(device.id)
        try await session.load(pcm, url: pcmURL, autoplay: true)
        try await assertPCMAdvances(session, device: device, context: "initial PCM")
        for rate in [2_822_400, 5_644_800] {
            session.followSourceSampleRate = rate == 5_644_800
            let url = directory.appendingPathComponent("silence-\(rate).dsf")
            try dsfSilence(rate: rate, seconds: 8).write(to: url)
            let media = MediaFile(rootID: "fixture", relativePath: url.lastPathComponent, title: "DSD silence", codec: "DSD (DSF)", sampleRate: Double(rate), channels: 2)
            try await session.load(media, url: url, autoplay: true)
            try await Task.sleep(nanoseconds: 600_000_000)
            session.refresh()
            XCTAssertTrue(session.isDoP)
            XCTAssertTrue(session.isPlaying, session.status)
            XCTAssertGreaterThan(session.dopDiagnostics?.callbacks ?? 0, 0)
            XCTAssertFalse(session.dopDiagnostics?.fault ?? true)
            try await session.load(pcm, url: pcmURL, autoplay: true)
            try await assertPCMAdvances(session, device: device, context: "DSD\(rate / 44_100) → PCM")
            session.pause()
            try session.start()
            try await assertPCMAdvances(session, device: device, context: "PCM pause/resume")
        }
        // A stop during the asynchronous format transition must cancel autoplay.
        for delay: UInt64 in [50_000_000, 450_000_000] {
            try session.chooseDevice(device.id)
            let pending = Task { try await session.load(pcm, url: pcmURL, autoplay: true) }
            try await Task.sleep(nanoseconds: delay)
            XCTAssertTrue(session.preparingOutput)
            session.stop()
            do { try await pending.value; XCTFail("Stopped load must be cancelled") }
            catch is CancellationError { }
            XCTAssertFalse(session.isPlaying)
            XCTAssertFalse(session.preparingOutput)
        }
    }

    @MainActor private func assertPCMAdvances(_ session: PlaybackSession, device: OutputDevice, context: String) async throws {
        let initial = session.position
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            session.refresh()
            XCTAssertTrue(session.isPlaying, "\(context): \(session.status)")
        }
        XCTAssertFalse(session.isDoP)
        XCTAssertEqual(session.actualDeviceID, device.id)
        XCTAssertGreaterThan(session.position, initial + 0.8, "\(context): \(session.status)")
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var owner: pid_t = 0, size = UInt32(MemoryLayout<pid_t>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &owner), noErr)
        XCTAssertEqual(owner, -1, "PCM must release DoP exclusive ownership")
        print("\(context): \(session.status), position=\(session.position), rate=\(session.outputRate)")
    }

    private func dsfSilence(rate: Int, seconds: Int) -> Data {
        func integer(_ value: UInt64, bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        let samples = rate * seconds, blocks = (samples / 8 + 4095) / 4096
        var data = Data("DSD ".utf8)
        for value in [28, 92 + blocks * 8192, 0] { data += integer(UInt64(value), bytes: 8) }
        data += Data("fmt ".utf8); data += integer(52, bytes: 8)
        for value in [1, 0, 2, 2, rate, 8] { data += integer(UInt64(value), bytes: 4) }
        data += integer(UInt64(samples), bytes: 8); data += integer(4096, bytes: 4)
        data += Data(repeating: 0, count: 4)
        data += Data("data".utf8); data += integer(UInt64(blocks * 8192 + 12), bytes: 8)
        data += Data(repeating: 0x69, count: blocks * 8192)
        return data
    }
}
