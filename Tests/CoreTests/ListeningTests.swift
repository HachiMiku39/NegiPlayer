import XCTest
import AudioCore
import AVFoundation

final class ListeningTests: XCTestCase {
    func testReplayGainAlbumFallbackMissingAndPeakHeadroom() {
        var s = PlaybackPreferences(); s.loudnessMode = .album
        let tags = ["REPLAYGAIN_TRACK_GAIN":["+6.0 dB"], "REPLAYGAIN_TRACK_PEAK":["0.5"], "REPLAYGAIN_ALBUM_GAIN":["-3.25 dB"]]
        XCTAssertEqual(LoudnessPolicy.adjustment(tags:tags,settings:s).gainDB,-3.25)
        s.headroomDB = 3
        let fallback = LoudnessPolicy.adjustment(tags:["replaygain_track_gain":["+10 dB"],"REPLAYGAIN_TRACK_PEAK":["1.0"]],settings:s)
        XCTAssertEqual(fallback.gainDB,-3,accuracy:0.0001)
        XCTAssertTrue(fallback.peakLimited); XCTAssertTrue(fallback.status.contains("专辑标签缺失"))
        let missing = LoudnessPolicy.adjustment(tags:["REPLAYGAIN_TRACK_GAIN":["nan","12oops"]],settings:s)
        XCTAssertEqual(missing.gainDB,-3); XCTAssertTrue(missing.status.contains("无有效"))
        s.loudnessMode = .off; s.loudnessPreampDB = 12
        XCTAssertEqual(LoudnessPolicy.adjustment(tags:tags,settings:s).gainDB,-3)
        s.loudnessMode = .track; s.preventPeakOverload = false
        XCTAssertEqual(LoudnessPolicy.adjustment(tags:["REPLAYGAIN_TRACK_GAIN":["+6 dB"]],settings:s).gainDB,15)
    }
    func testSettingsRestartVolumeCeilingAndUnknownVersionPreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = PlaybackPreferencesStore(url:folder.appendingPathComponent("PlaybackSettings.json"))
        var s = PlaybackPreferences(); s.volume = 0.8; s.volumeLimit = 0.25; s.headroomDB = 3
        s.preferredDeviceUID = "stable-dac-uid"; s.loudnessMode = .album; s.gains = [99,-99]
        try store.save(s)
        let restored = try store.load()
        XCTAssertEqual(restored.volume,0.25); XCTAssertEqual(restored.headroomDB,3)
        XCTAssertEqual(restored.gains,[12,-12,0,0,0,0,0,0,0,0]); XCTAssertEqual(restored.preferredDeviceUID,"stable-dac-uid")
        var future = restored; future.version = 20
        let bytes = try JSONEncoder().encode(future); try bytes.write(to:store.url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf:store.url),bytes)
        s.volume = .nan; s.volumeLimit = .infinity
        XCTAssertEqual(s.sanitized().volume,0); XCTAssertEqual(s.sanitized().volumeLimit,1)
    }
    func testMetadataPeakBudgetIncludesEQBoostAndHeadroom() {
        var s = PlaybackPreferences(); s.loudnessMode = .track; s.eqEnabled = true; s.gains[4] = 6; s.eqPreampDB = -3; s.headroomDB = 2
        let a = LoudnessPolicy.adjustment(tags:["REPLAYGAIN_TRACK_GAIN":["+10 dB"],"REPLAYGAIN_TRACK_PEAK":["1"]],settings:s)
        XCTAssertEqual(a.gainDB,-5,accuracy:0.0001); XCTAssertTrue(a.peakLimited)
        s.eqEnabled = false
        XCTAssertEqual(LoudnessPolicy.adjustment(tags:["REPLAYGAIN_TRACK_GAIN":["+10 dB"],"REPLAYGAIN_TRACK_PEAK":["1"]],settings:s).gainDB,-2,accuracy:0.0001)
    }
    func testActualOfflinePCMPreGainAndBypass() throws {
        let report: PCMPreGainReport
        if let path = ProcessInfo.processInfo.environment["NEGI_NATIVE_DSP_REPORT"] {
            report = try JSONDecoder().decode(PCMPreGainReport.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        } else { report = try PCMPreGainVerification.measure() }
        XCTAssertEqual(report.sampleRate,48000); XCTAssertEqual(report.channels,2); XCTAssertEqual(report.gainDB,-6)
        XCTAssertEqual(report.inputAmplitude,0.25); XCTAssertEqual(report.bypassMean,0.25,accuracy:0.0001)
        XCTAssertEqual(report.processedMean/report.bypassMean,Float(pow(10.0,-6.0/20)),accuracy:0.002)
    }
}
