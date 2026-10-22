import XCTest
import AudioCore

final class AudioTests: XCTestCase {
    func testIndependentDoPByteLayoutAndBoundaryContinuity() throws {
        var packer = DoPPacker(channels: 2)
        let first = try packer.pack([[0x11, 0x22, 0x33], [0xAA, 0xBB, 0xCC]])
        XCTAssertEqual(Array(first), [0x22, 0x11, 0x05, 0xBB, 0xAA, 0x05])
        let second = try packer.pack([[0x44, 0x55], [0xDD, 0xEE]])
        XCTAssertEqual(Array(second), [0x44, 0x33, 0xFA, 0xDD, 0xCC, 0xFA])
        let tail = try packer.pack([[], []], finish: true)
        XCTAssertEqual(Array(tail), [0x69, 0x55, 0x05, 0x69, 0xEE, 0x05])
        // Independent unpacking: stride 6, older byte occupies bits 15…8. Known markers checked above.
        let all = Array(first+second+tail)
        let left = stride(from: 0, to: all.count, by: 6).flatMap { [all[$0+1], all[$0]] }
        let right = stride(from: 3, to: all.count, by: 6).flatMap { [all[$0+1], all[$0]] }
        XCTAssertEqual(Array(left.prefix(5)), [0x11,0x22,0x33,0x44,0x55])
        XCTAssertEqual(Array(right.prefix(5)), [0xAA,0xBB,0xCC,0xDD,0xEE])
        packer.resetAfterSeek()
        XCTAssertEqual(Array(try packer.pack([[1,2],[3,4]])), [2,1,5,4,3,5])
        XCTAssertThrowsError(try packer.pack([[1],[]]))
    }
    func testEventClockPauseSeekAndRateMapping() {
        let playing = PlaybackAnchor(mediaSeconds: 10, eventUptime: 100, running: true)
        XCTAssertEqual(playing.mediaTime(at: 99.9), 9.9, accuracy: 0.000001)
        let paused = PlaybackAnchor(mediaSeconds: 10, eventUptime: 100, running: false)
        XCTAssertEqual(paused.mediaTime(at: 600), 10)
        let seeked = PlaybackAnchor(mediaSeconds: 700, eventUptime: 200, rate: 0.5, running: true)
        XCTAssertEqual(seeked.mediaTime(at: 202), 701)
    }
    func testDirectTransitionMustPauseBeforeRemovingAttenuation() {
        XCTAssertTrue(VolumeTransition.enteringDirect(fromGain: 0.5, preampDB: 0, verifiedHardwareControl: false).mustPause)
        XCTAssertTrue(VolumeTransition.enteringDirect(fromGain: 1, preampDB: -6, verifiedHardwareControl: false).mustPause)
        XCTAssertFalse(VolumeTransition.enteringDirect(fromGain: 1, preampDB: 0, verifiedHardwareControl: false).mustPause)
    }
}
