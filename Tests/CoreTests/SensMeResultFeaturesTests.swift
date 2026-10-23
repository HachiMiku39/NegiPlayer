import XCTest
import CryptoKit
import CSensMeCore

final class SensMeResultFeaturesTests: XCTestCase {
    private struct Fixture: Decodable {
        let kind, pattern, SHA256: String
        let count: Int
    }
    private struct Fixtures: Decodable { let cases: [Fixture] }
    private struct Input {
        var beats: [NegiSensMeBeat]
        var keys: [NegiSensMeSectionKey]
        var sections: [Int32]
        var summaries: [Float]
    }
    private func input(_ fixture: Fixture) -> Input {
        var seed: UInt32 = 0x39cf1373
        func word() -> UInt32 {
            seed = 1664525 &* seed &+ 1013904223
            return seed >> 16
        }
        let n = fixture.count, kind = fixture.kind, pattern = fixture.pattern
        var beats = [NegiSensMeBeat](repeating: .init(), count: n)
        var keys = [NegiSensMeSectionKey](repeating: .init(), count: n)
        var sections = [Int32]()
        for i in 0..<n {
            var cls = Int32(word() % 24)
            if kind == "constant" { cls = 21 }
            else if kind == "zero" { cls = 0 }
            else if kind == "cycle" { cls = [0, 5, 7, 0, 21, 2, 4, 21, 14, 16][i % 10] }
            var root = Int32(word() % 12)
            if ["zero", "constant", "cycle"].contains(kind) { root = 0 }
            let label: Int32 = pattern == "none" ? -1 : pattern == "one" ? 0 : pattern == "blocks" ? Int32(i / 16 % 3) : Int32(i % 2)
            beats[i].milliseconds = Float(31.25 + Double(i * (n > 480 ? 250 : 500)))
            beats[i].bar = Int32(i / 4); beats[i].beat = Int32(i % 4 + 1); beats[i].tonal_class = cls
            keys[i].root = root; sections.append(label)
            for column in 0..<36 {
                var value = Double(word())/65536
                if kind == "zero" { value = 0 }
                else if kind == "constant" { value = 0.5 }
                if column < 24 {
                    withUnsafeMutableBytes(of: &beats[i]) { $0.storeBytes(of: Float(value), toByteOffset: 16 + 4 * column, as: Float.self) }
                } else {
                    withUnsafeMutableBytes(of: &keys[i]) { $0.storeBytes(of: Float(value), toByteOffset: 4 + 4 * (column - 24), as: Float.self) }
                }
            }
        }
        var summaries = [Float]()
        for column in 0..<128 {
            var value = Double(word())/65536
            let small = [4, 5, 6, 7].contains(column % 16)
            if small { value /= 16777216 }
            if kind == "zero" { value = 0 }
            else if kind == "constant" { value = small ? 1/16777216 : 1 }
            else if kind == "wide" { value *= 8 }
            summaries.append(Float(value))
        }
        return Input(beats: beats, keys: keys, sections: sections, summaries: summaries)
    }
    private func digest<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }
    private func collect(_ source: Input, kind: String = "random", chorus: Int? = nil, output: inout NegiSensMeResultFeatures) -> Int32 {
        negi_sensme_result_features(source.beats, source.keys, source.sections, source.beats.count, source.summaries,
            kind == "zero" ? 0 : 127.5, kind == "zero" ? 0 : 3.25, kind == "zero" ? 0 : 0.25,
            0, chorus ?? source.beats.count / 3, &output)
    }

    func testAllFinalFeaturesAgainstOriginalCollector() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeResultFeatures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url)).cases
        XCTAssertEqual(fixtures.count, 80); XCTAssertEqual(MemoryLayout<NegiSensMeResultFeatures>.size, 756)
        for fixture in fixtures {
            let source = input(fixture)
            var result = NegiSensMeResultFeatures()
            XCTAssertEqual(collect(source, kind: fixture.kind, output: &result), 1)
            XCTAssertEqual(digest(result), fixture.SHA256, "\(fixture.kind) \(fixture.pattern) \(fixture.count)")
        }
    }

    func testInvalidInputLeavesFeaturesUnchanged() {
        let valid = input(Fixture(kind: "random", pattern: "blocks", SHA256: "", count: 24))
        var result = NegiSensMeResultFeatures()
        _ = withUnsafeMutableBytes(of: &result) { $0.initializeMemory(as: UInt8.self, repeating: 0xa5) }
        let initial = digest(result)
        for variant in 0..<10 {
            var source = valid
            switch variant {
            case 0: source.beats[1].milliseconds = .nan
            case 1: source.beats[1].milliseconds = source.beats[0].milliseconds
            case 2: source.beats[0].tonal_class = 24
            case 3: source.keys[0].root = 12
            case 4: source.sections[0] = -2
            case 5: source.summaries[127] = .infinity
            case 6: source.summaries[68] = -1
            case 7: withUnsafeMutableBytes(of: &source.keys[0]) { $0.storeBytes(of: Float.nan, toByteOffset: 4, as: Float.self) }
            case 8: withUnsafeMutableBytes(of: &source.beats[0]) { $0.storeBytes(of: Float(2), toByteOffset: 16, as: Float.self) }
            default: source.summaries[0] = .greatestFiniteMagnitude
            }
            XCTAssertEqual(collect(source, output: &result), 0, "variant \(variant)")
            XCTAssertEqual(digest(result), initial)
        }
        XCTAssertEqual(negi_sensme_result_features(nil, valid.keys, valid.sections, 24, valid.summaries, 0, 0, 0, 0, 0, &result), 0)
        XCTAssertEqual(digest(result), initial)
    }

    func testTimestampCapacityGuard() {
        // Two additions in one iteration would reach the original count word.
        // The native API refuses this input before committing any output.
        let source = input(Fixture(kind: "random", pattern: "alternating", SHA256: "", count: 66))
        var result = NegiSensMeResultFeatures()
        let initial = digest(result)
        XCTAssertEqual(collect(source, chorus: 1, output: &result), 0)
        XCTAssertEqual(digest(result), initial)
    }
}
