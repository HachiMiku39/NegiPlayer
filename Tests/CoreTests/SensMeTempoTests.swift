import XCTest
import CryptoKit
import CSensMeCore

final class SensMeTempoTests: XCTestCase {
    private struct Fixture {
        let candidate, adjusted: Int32
        let votes: [Int32]
        let doubles: [UInt64]
        let floats: [UInt32]
        let weightedHash: String
    }
    private var fixtures: [Fixture] { [
            Fixture(candidate: 160, adjusted: 160, votes: [4, 4, 4, 6, 3, 2, 0, 4, 3],
                doubles: [0x40b1b4cccccccccd, 0x4039cd5555555555, 0x40b1b50000000000, 0x4069cd5555555555, 0x40b2360000000000],
                floats: [0x401d49aa, 0x4213c408, 0x434e6aab, 0x42f1aaab],
                weightedHash: "429a471cc2368d2a88cf3ac3c4589793b65792df8f6ee62179f857b38cd9279c"),
            Fixture(candidate: 271, adjusted: 135, votes: [6, 4, 6, 5, 4, 4, 4, 4, 4],
                doubles: [0x407ccea45e77069d, 0x403e9855f7268eda, 0x407cd00000000000, 0x406e9855f7268eda, 0x407d700000000000],
                floats: [0x401d49aa, 0x41f93be4, 0x4374c2b0, 0x43623d50],
                weightedHash: "372a2a268662f944b5a66a24c8e88122e6dc6d463a4e6bbc53c23eefed0b1682"),
            Fixture(candidate: 0, adjusted: 1, votes: [0, 0, 0, 0, 0, 0, 0, 0, 0],
                doubles: [0x0, 0x40b0000000000000, 0x0, 0x4050000000000000, 0x0],
                floats: [0x409db1dd, 0x42ee4aa0, 0x42800000, 0x0],
                weightedHash: "a48188fb7d1bd0a9ce64490283992b8d31ab3b1e2e699ef776fa1f0b08cdaa84"),
            Fixture(candidate: 511, adjusted: 127, votes: [4, 7, 3, 6, 4, 4, 3, 6, 4],
                doubles: [0x4050080402010080, 0x40405d0f743dd0f7, 0x4051800000000000, 0x40705d0f743dd0f7, 0x4051800000000000],
                floats: [0x401d49aa, 0x41e8ff72, 0x4382e87c, 0x428c0000],
                weightedHash: "8c5abe332c1de0b6bc6db3a434dbcbe0826cb5dcfe7d82770120e553940eedd0"),
    ] }

    private func input(_ kind: Int) -> ([Int32], [Float], [Float]) {
        let frames = 12416
        let patterns: [[Int32]] = [
            [320, 640, 321, 160, 319, 318, 0, 642, 322],
            [271, 542, 270, 135, 272, 541, 540, 269, 543],
            Array(repeating: 0, count: 9),
            [1022, 511, 1021, 510, 255, 1023, 1024, 512, 256]
        ]
        var seed: UInt32 = 0x39BEEFBF
        var onsets: [Float] = []
        for band in 0..<3 {
            for i in 0..<frames {
                seed = 1664525 &* seed &+ 1013904223
                let value: Float
                if kind == 2 { value = 0 }
                else if kind == 3 { value = (i + band) % 5 == 0 ? 4096 : 0 }
                else { value = Float((seed >> 24) & 127)/256 + (i % (43 + kind*7 + band) < 2 ? 12 : 0) + Float(i % 97)/64 }
                onsets.append(value)
            }
        }
        seed = 0x39DEC0DE
        let bases = [65536, 0, 0, 65536, 0, 0, 0, 0, 1024, 10240, 32768, 32768, 32768, 8192, 512, 4096]
        var stats: [Float] = []
        for _ in 0..<(frames/128) {
            for column in 0..<32 {
                seed = 1664525 &* seed &+ 1013904223
                let stream = column % 16
                let value: Float
                if kind == 2 { value = 0 }
                else if column < 16 {
                    value = (4...7).contains(stream) ? Float((seed >> 24) & 31)/268435456 : Float(bases[stream] + Int((seed >> 24) & 127) - 64)/65536
                } else {
                    value = (4...7).contains(stream) ? Float((seed >> 24) & 31)/16777216 : stream == 3 ? 0 : Float(512 + ((seed >> 24) & 127))/65536
                }
                stats.append(value)
            }
        }
        return (patterns[kind], onsets, stats)
    }

    func testVotingAgainstAuditedSyntheticCounters() {
        for kind in 0..<4 {
            var candidates = input(kind).0
            var votes = [Int32](repeating: -1, count: 9)
            XCTAssertEqual(negi_sensme_tempo_vote(&candidates, candidates.count, &votes), fixtures[kind].candidate)
            XCTAssertEqual(votes, fixtures[kind].votes)
        }
    }

    func testPeriodsPhasesAndBPMAgainstAuditedSyntheticStages() {
        // Original DLL runs with self-generated stage inputs. Observation-only
        // callbacks preserve all x87/SSE state; complete results were compared
        // to separate input-injection-only runs. No music/DLL is needed here.
        for kind in 0..<4 {
            var (candidates, onsets, stats) = input(kind)
            var output = NegiSensMeTempoEstimate()
            var weighted = [Float](repeating: 0, count: 12416)
            XCTAssertEqual(negi_sensme_tempo_refine(&candidates, candidates.count, &onsets, 12416, &stats, &output, &weighted), 1)
            let expected = fixtures[kind]
            XCTAssertEqual(output.selected_candidate, expected.candidate)
            XCTAssertEqual(output.adjusted_candidate, expected.adjusted)
            XCTAssertEqual([output.initial_phase, output.refined_period, output.first_phase, output.final_period, output.final_phase].map(\.bitPattern), expected.doubles, "case \(kind)")
            XCTAssertEqual([output.predicted_log_bpm, output.bpm, output.period_frames, output.phase_frames].map(\.bitPattern), expected.floats, "case \(kind)")
            let digest = SHA256.hash(data: weighted.withUnsafeBytes { Data($0) }).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, expected.weightedHash)
        }
    }

    func testInvalidTempoInputsLeaveEstimateUnchanged() {
        var candidates: [Int32] = [0, 0, 0]
        var votes: [Int32] = [9, 9, 9]
        XCTAssertEqual(negi_sensme_tempo_vote(nil, 3, &votes), -1)
        XCTAssertEqual(negi_sensme_tempo_vote(&candidates, 0, &votes), -1)
        XCTAssertEqual(negi_sensme_tempo_vote(&candidates, 31, &votes), -1)
        candidates[0] = -1
        XCTAssertEqual(negi_sensme_tempo_vote(&candidates, 3, &votes), -1)
        candidates[0] = 2048
        XCTAssertEqual(negi_sensme_tempo_vote(&candidates, 3, &votes), -1)
        XCTAssertEqual(votes, [9, 9, 9])
        candidates[0] = 0
        var onsets = [Float](repeating: 0, count: 3*128)
        var stats = [Float](repeating: 0, count: 32)
        var output = NegiSensMeTempoEstimate(); output.bpm = 9
        XCTAssertEqual(negi_sensme_tempo_refine(nil, 3, &onsets, 128, &stats, &output, nil), 0)
        XCTAssertEqual(negi_sensme_tempo_refine(&candidates, 2, &onsets, 128, &stats, &output, nil), 0)
        XCTAssertEqual(negi_sensme_tempo_refine(&candidates, 3, &onsets, 127, &stats, &output, nil), 0)
        onsets[0] = .nan
        XCTAssertEqual(negi_sensme_tempo_refine(&candidates, 3, &onsets, 128, &stats, &output, nil), 0)
        onsets[0] = 0; stats[0] = .infinity
        XCTAssertEqual(negi_sensme_tempo_refine(&candidates, 3, &onsets, 128, &stats, &output, nil), 0)
        XCTAssertEqual(output.bpm, 9)
    }

    func testEmptyWindowMatchesOriginalDiagnosticWithoutPublishingBPM() {
        // Nine independent original complete runs (silence and very short
        // generated noise) reached zero complete statistics blocks.
        var estimate = NegiSensMeTempoEstimate()
        var onset: Float = 0, statistic: Float = 0
        XCTAssertEqual(negi_sensme_tempo_refine([0, 0, 0], 3, &onset, 0, &statistic, &estimate, nil), 1)
        XCTAssertEqual(estimate.predicted_log_bpm.bitPattern, 0x409db1dd)
        XCTAssertEqual(estimate.bpm.bitPattern, 0x42ee4aa0)
        XCTAssertEqual(estimate.period_frames, 64)
        XCTAssertEqual(estimate.phase_frames, 0)
        // The formatter's short-track gate omits GBPM for this diagnostic.
    }
}
