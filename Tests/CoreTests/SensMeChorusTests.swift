import XCTest
import CryptoKit
import CSensMeCore

final class SensMeChorusTests: XCTestCase {
    private struct Fixture: Decodable {
        let kind, pattern, runSHA256: String
        let count, types, blockCount, scoredRuns: Int
        let selected: [Int32]
        let typeScoreBits: [UInt32]
        let unobservedVerified: Bool
    }
    private struct Fixtures: Decodable { let cases: [Fixture] }
    private struct LikelihoodFixture: Decodable {
        let firstFallbackBits: [UInt32]
        let cases: Int
        let outputSHA256: String
    }
    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeChorus", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url)).cases
    }
    private func digest<T>(_ values: [T]) -> String {
        values.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }

    // Matches the documented, music-independent input generator used by the
    // original-engine oracle; all expected run bytes come from that engine.
    private func input(_ fixture: Fixture) -> ([Float], [Int32], [Float]) {
        let times = (0..<fixture.count).map { Float(31.25 + Double($0 * (fixture.count > 480 ? 250 : 500))) }
        let labels: [Int32] = (0..<fixture.count).map { i in
            switch fixture.pattern {
            case "none": return -1
            case "one": return 0
            case "tail": return 4 <= i && i < fixture.count - 8 ? 0 : -1
            case "repeats2": return Int32(i / 16 % 2)
            case "repeats3": return [-1, 0, 1, 2][i / 13 % 4]
            case "uneven": return [0, 1, 2, -1, 1, 0][i / 7 % 6]
            default: return Int32(i % 2)
            }
        }
        var blocks = [Float](), seed: UInt32 = 0x39c407a1
        for block in 0..<fixture.blockCount {
            for column in 0..<32 {
                seed = 1664525 &* seed &+ 1013904223
                var value = fixture.kind == "constant" ? 64 : Int(seed >> 16 & 255)
                if fixture.kind == "zero" || (fixture.kind == "sparse" && block % 7 < 4) { value = 0 }
                let divisor = [4, 5, 6, 7].contains(column % 16) ? 16777216 : column < 16 ? 256 : 1024
                var result = Float(value) / Float(divisor)
                if column == 3 && fixture.kind != "zero" { result = 1 }
                if column == 5 && fixture.kind == "transient" { result = Float(block % 4 + 1) / 2048 }
                if column == 17 && fixture.kind == "large" { result = Float((block % 4 + 1) * 2) }
                blocks.append(result)
            }
        }
        return (times, labels, blocks)
    }

    func testDefaultModelRunScalarsAndSelectionAgainstAuditedEngine() throws {
        let cases = try fixtures()
        XCTAssertEqual(cases.count, 126); XCTAssertEqual(cases.reduce(0) { $0 + $1.scoredRuns }, 9246)
        XCTAssertEqual(MemoryLayout<NegiSensMeChorusRun>.size, 32)
        for fixture in cases {
            XCTAssertTrue(fixture.unobservedVerified)
            let (times, labels, blocks) = input(fixture)
            var runs = [NegiSensMeChorusRun](repeating: .init(), count: fixture.count)
            var scores = [Float](repeating: 0, count: fixture.types)
            var selection = NegiSensMeChorusSelection()
            XCTAssertEqual(negi_sensme_chorus_select(times, labels, fixture.count, fixture.types, blocks,
                fixture.blockCount, &selection, &scores, &runs), 1)
            XCTAssertEqual([selection.section_type, Int32(selection.beat_index)], fixture.selected)
            XCTAssertEqual(Int(selection.scored_runs), fixture.scoredRuns)
            XCTAssertEqual(scores.map(\.bitPattern), fixture.typeScoreBits)
            XCTAssertEqual(digest(Array(runs.prefix(fixture.scoredRuns))), fixture.runSHA256,
                "\(fixture.kind) \(fixture.pattern) \(fixture.count)")
        }
    }

    func testNoSectionsAndOptionalDiagnostics() throws {
        var selection = NegiSensMeChorusSelection()
        selection.section_type = 9; selection.beat_index = 9; selection.scored_runs = 9
        XCTAssertEqual(negi_sensme_chorus_select([0, 500], [-1, -1], 2, 0,
            [Float](repeating: 0, count: 32), 1, &selection, nil, nil), 1)
        XCTAssertEqual(selection.section_type, 0); XCTAssertEqual(selection.beat_index, 0); XCTAssertEqual(selection.scored_runs, 0)
        let fixture = try XCTUnwrap(try fixtures().first { $0.pattern == "tail" })
        let (times, labels, blocks) = input(fixture)
        XCTAssertEqual(negi_sensme_chorus_select(times, labels, fixture.count, fixture.types, blocks,
            fixture.blockCount, &selection, nil, nil), 1)
        XCTAssertEqual([selection.section_type, Int32(selection.beat_index)], fixture.selected)
    }

    func testFinalFrameSurvivesMillisecondFloatRoundTrip() {
        let rate = Float(bitPattern: 0x3e022391)
        let finalTime = Float(38016 / Double(rate))
        XCTAssertGreaterThan(Double(finalTime) * Double(rate), 38016)
        XCTAssertEqual(Int(Double(finalTime) * Double(rate)), 38016)
        var selection = NegiSensMeChorusSelection()
        let stats = [Float](repeating: 0, count: 297 * 32)
        XCTAssertEqual(negi_sensme_chorus_select([0, finalTime], [-1, -1], 2, 0,
            stats, 297, &selection, nil, nil), 1)
        selection.section_type = 9
        XCTAssertEqual(negi_sensme_chorus_select([0, Float(38018 / Double(rate))], [-1, -1], 2, 0,
            stats, 297, &selection, nil, nil), 0)
        XCTAssertEqual(selection.section_type, 9)
    }

    func testInvalidInputLeavesAllOutputsUnchanged() {
        let times: [Float] = [0, 500, 1000, 1500], labels: [Int32] = [0, 0, -1, -1]
        var selection = NegiSensMeChorusSelection(); selection.section_type = 9; selection.beat_index = 9; selection.scored_runs = 9
        var scores: [Float] = [-7, -7], runs = [NegiSensMeChorusRun](repeating: .init(), count: 4)
        runs[0].probability = -7; let before = digest(runs)
        for variant in 0..<10 {
            var t = times, l = labels, stats = [Float](repeating: 0, count: 32)
            var count = 4, types = 1, blocks = 1
            switch variant {
            case 0: t[3] = .nan
            case 1: t[3] = t[2]
            case 2: t[3] = 400000
            case 3: l[3] = 1
            case 4: l[3] = -2
            case 5: stats[31] = .nan
            case 6: types = 2
            case 7: types = 100
            case 8: blocks = 298
            default: count = 961
            }
            XCTAssertEqual(negi_sensme_chorus_select(t, l, count, types, stats, blocks, &selection, &scores, &runs), 0)
            XCTAssertEqual(selection.section_type, 9); XCTAssertEqual(selection.beat_index, 9); XCTAssertEqual(selection.scored_runs, 9)
            XCTAssertEqual(scores, [-7, -7]); XCTAssertEqual(digest(runs), before)
        }
    }

    func testLikelihoodBoundaryAndGeneratedScoresAgainstOriginalHelper() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeChorusLikelihood", withExtension: "json"))
        let fixture = try JSONDecoder().decode(LikelihoodFixture.self, from: Data(contentsOf: url))
        var output = [UInt32]()
        for boundary in fixture.firstFallbackBits {
            let sign = boundary & 0x80000000, magnitude = boundary & 0x7fffffff
            for step in -16...16 {
                let input = UInt32(Int(magnitude) + step) | sign
                output.append(negi_sensme_chorus_probability(Float(bitPattern: input)).bitPattern)
            }
            XCTAssertEqual(negi_sensme_chorus_probability(Float(bitPattern: boundary)).bitPattern, boundary)
        }
        var seed: UInt32 = 0x39c0a055
        for _ in 0..<16384 {
            seed = 1664525 &* seed &+ 1013904223
            let value = Float(Double(Int((seed >> 8) % 10000000) - 5000000) / 1024)
            output.append(negi_sensme_chorus_probability(value).bitPattern)
        }
        XCTAssertEqual(output.count, fixture.cases); XCTAssertEqual(digest(output), fixture.outputSHA256)
        XCTAssertEqual(negi_sensme_chorus_probability(.infinity), .infinity)
        XCTAssertTrue(negi_sensme_chorus_probability(.nan).isNaN)
    }
}
