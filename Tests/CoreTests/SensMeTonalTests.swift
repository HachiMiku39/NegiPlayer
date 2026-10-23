import XCTest
import CryptoKit
import CSensMeCore

final class SensMeTonalTests: XCTestCase {
    private struct TonalFixture: Decodable {
        let kind: String
        let start, frames: Int
        let selected: Int32
        let probabilitiesSHA256: String
    }
    private struct GridFixture: Decodable {
        let kind: String
        let frames, preliminaryCount, count: Int
        let periodBits, phaseBits, alignedPhaseBits: UInt32
        let downbeatOffset: Int32
        let scoreBits: [UInt32]
        let gridSHA256: String
        let observationPreservedFullResult, nativeExact: Bool
    }
    private struct Fixtures<T: Decodable>: Decodable { let cases: [T] }

    private func load<T: Decodable>(_ name: String, _: T.Type) throws -> [T] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(Fixtures<T>.self, from: Data(contentsOf: url)).cases
    }

    private func digest<T>(_ values: [T]) -> String {
        values.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }

    // Same documented generator as synthetic_tonal_input.py. No DLL, VM,
    // audio file or captured private feature data is needed by these tests.
    private func tones(_ kind: String) -> [[UInt16]] {
        var seed: UInt32 = 0x39da7a11
        return (0..<2).map { group in
            var values = [UInt16](); values.reserveCapacity(19008 * 12)
            for pair in 0..<19008 {
                for tone in 0..<12 {
                    seed = 1664525 &* seed &+ 1013904223
                    let value: Int
                    switch kind {
                    case "zero": value = 0
                    case "constant": value = 12345 + group
                    case "random": value = Int(seed >> 16)
                    case "ramp": value = (pair * 7 + tone * 361 + group * 53) & 65535
                    case "limits": value = [0, 65535, 1, 32768, 65534][(pair + tone + group) % 5]
                    case "single": value = tone == (pair / 500 + group) % 12 ? 60000 : 33
                    case "triad": value = [0, 4, 7].contains(((tone - pair / 1000 - group) % 12 + 12) % 12) ? 36000 : 1234
                    case "near-flat": value = 32768 + Int(seed >> 31)
                    default: preconditionFailure("Unknown fixture")
                    }
                    values.append(UInt16(value))
                }
            }
            return values
        }
    }

    func testGeneratedTonalProbabilitiesMatchAuditedEngine() throws {
        let fixtures = try load("SensMeTonal", TonalFixture.self)
        XCTAssertEqual(fixtures.count, 80)
        var previous = "", groups = [[UInt16]]()
        for fixture in fixtures {
            if fixture.kind != previous { groups = tones(fixture.kind); previous = fixture.kind }
            var output = [Float](repeating: -1, count: 24)
            let selected = negi_sensme_tonal_features(groups[0], groups[1], 19008, fixture.start, fixture.frames, &output)
            XCTAssertEqual(selected, fixture.selected, "\(fixture.kind) start \(fixture.start)")
            XCTAssertEqual(digest(output), fixture.probabilitiesSHA256, "\(fixture.kind) start \(fixture.start)")
        }
    }

    func testGeneratedBeatGridsMatchFullAnalysisObservations() throws {
        let fixtures = try load("SensMeBeatGrid", GridFixture.self)
        XCTAssertEqual(fixtures.count, 4)
        XCTAssertEqual(MemoryLayout<NegiSensMeBeat>.size, 168)
        for fixture in fixtures {
            XCTAssertTrue(fixture.observationPreservedFullResult); XCTAssertTrue(fixture.nativeExact)
            let groups = tones(fixture.kind)
            var beats = [NegiSensMeBeat](repeating: .init(), count: 960)
            var summary = NegiSensMeBeatGridSummary()
            XCTAssertEqual(negi_sensme_beat_grid(groups[0], groups[1], fixture.frames,
                Float(bitPattern: fixture.periodBits), Float(bitPattern: fixture.phaseBits), &beats, 960, &summary), 1)
            XCTAssertEqual(summary.preliminary_count, fixture.preliminaryCount)
            XCTAssertEqual(summary.count, fixture.count); XCTAssertEqual(summary.downbeat_offset, fixture.downbeatOffset)
            XCTAssertEqual([summary.downbeat_scores.0, summary.downbeat_scores.1,
                summary.downbeat_scores.2, summary.downbeat_scores.3].map(\.bitPattern), fixture.scoreBits)
            XCTAssertEqual(summary.aligned_phase_frames.bitPattern, fixture.alignedPhaseBits)
            XCTAssertEqual(digest(Array(beats.prefix(fixture.count))), fixture.gridSHA256)
        }
    }

    func testInvalidTonalInputLeavesOutputUnchanged() {
        let values = [UInt16](repeating: 1, count: 24)
        var output = [Float](repeating: -1, count: 24)
        for (pairs, start) in [(0, 0), (19009, 0), (1, 3), (Int.max, 0)] {
            XCTAssertEqual(negi_sensme_tonal_features(values, values, pairs, start, 2, &output), -1)
            XCTAssertEqual(output, [Float](repeating: -1, count: 24))
        }
        XCTAssertEqual(negi_sensme_tonal_features(nil, values, 1, 0, 2, &output), -1)
    }

    func testInvalidGridInputLeavesOutputsUnchanged() {
        let groups = tones("zero")
        var output = [NegiSensMeBeat](repeating: .init(), count: 960)
        output[0].milliseconds = -1
        var summary = NegiSensMeBeatGridSummary(); summary.count = 777
        for (frames, period, phase, capacity) in [(1, Float(64), Float(0), 960),
            (129, 64, 0, 960), (38144, 64, 0, 960), (128, 0, 0, 960),
            (128, .nan, 0, 960), (128, 64, .infinity, 960), (128, 64, 65, 960),
            (128, 256, 129, 960), (128, 64, 0, 0), (128, Float(Int32.max), 0, 960)] {
            XCTAssertEqual(negi_sensme_beat_grid(groups[0], groups[1], frames, period, phase, &output, capacity, &summary), 0)
            XCTAssertEqual(output[0].milliseconds, -1); XCTAssertEqual(summary.count, 777)
        }
    }

    func testRoundedPhaseCanEqualOnePeriod() {
        let groups = tones("zero")
        var output = [NegiSensMeBeat](repeating: .init(), count: 960)
        var summary = NegiSensMeBeatGridSummary()
        XCTAssertEqual(negi_sensme_beat_grid(groups[0], groups[1], 128, 64, 64,
            &output, 960, &summary), 1)
        XCTAssertEqual(summary.preliminary_count, 2)
        XCTAssertEqual(summary.count, 2)
        let rate = Float(bitPattern: 0x3e022391)
        XCTAssertEqual(output[0].milliseconds, Float(64 / Double(rate)))
        XCTAssertEqual(output[1].milliseconds, Float(128 / Double(rate)))
    }

    func testEmptyWindowProducesOriginalSingleDiagnosticBeat() {
        let groups = tones("zero")
        var output = NegiSensMeBeat(), summary = NegiSensMeBeatGridSummary()
        XCTAssertEqual(negi_sensme_beat_grid(groups[0], groups[1], 0, 64, 0, &output, 1, &summary), 1)
        XCTAssertEqual(summary.preliminary_count, 1)
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(output.milliseconds, 0)
        XCTAssertEqual(output.bar, 2); XCTAssertEqual(output.beat, 1); XCTAssertEqual(output.tonal_class, 12)
        withUnsafeBytes(of: output.probabilities) { bytes in
            for i in 0..<24 {
                XCTAssertEqual(bytes.load(fromByteOffset: i * 4, as: UInt32.self), i < 12 ? 0x3947bb0d : 0x39654671)
            }
        }
    }
}
