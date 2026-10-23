import XCTest
import CryptoKit
import CSensMeCore

final class SensMeAnalyzerTests: XCTestCase {
    private struct Case: Decodable {
        let kind: String
        let frames, leadingZeroFrames, processedFrames, encodedBytes: Int
        let encodedSHA256: String
    }
    private struct Fixture: Decodable { let dispatchFrames: Int; let cases: [Case] }
    private func load() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeAnalyzer", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func pattern(_ kind: String) -> [Int16] {
        let period = kind == "pulse" ? 22050 : 4096
        var seed: UInt32 = 0x39a17c11, result: [Int16] = []
        for i in 0..<period {
            seed = 1664525 &* seed &+ 1013904223
            var left = Int(seed >> 16) - 32768
            seed = 1664525 &* seed &+ 1013904223
            var right = Int(seed >> 16) - 32768
            switch kind {
            case "silence": left = 0; right = 0
            case "antiphase": left = max(-32767, left); right = -left
            case "pulse": left = i < 32 ? (32 - i) * 1000 : 0; right = left
            case "triangles":
                left = [200, 500, 1000].reduce(0) { sum, p in
                    let value = (abs(i % p - p / 2) * 4 - p) * 3000
                    return sum + (value >= 0 ? value / p : -((-value + p - 1) / p))
                }
                right = left
            default: break
            }
            result.append(Int16(left)); result.append(Int16(right))
        }
        return result
    }
    private func write(_ item: Case, to analyzer: OpaquePointer, stopAtSaturation: Bool = false) {
        let pattern = pattern(item.kind), period = pattern.count / 2
        var chunk = [Int16](repeating: 0, count: 8192)
        for start in stride(from: 0, to: item.frames, by: 4096) {
            let frames = min(4096, item.frames - start)
            chunk.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(repeating: 0, count: frames * 2)
                let silence = max(0, min(frames, item.leadingZeroFrames - start))
                var at = silence
                pattern.withUnsafeBufferPointer { source in
                    while at < frames {
                        let position = (start + at - item.leadingZeroFrames) % period
                        let count = min(frames - at, period - position)
                        destination.baseAddress!.advanced(by: at * 2).update(
                            from: source.baseAddress!.advanced(by: position * 2), count: count * 2)
                        at += count
                    }
                }
            }
            XCTAssertEqual(negi_sensme_analyzer_write(analyzer, chunk, frames), 1)
            if stopAtSaturation && negi_sensme_analyzer_needs_pcm(analyzer) == 0 { break }
        }
    }

    func testEarlyWindowFinishMatchesOriginalWholeInputResult() throws {
        let fixture = try load(), item = try XCTUnwrap(fixture.cases.first { $0.processedFrames == 38016 })
        let analyzer = try XCTUnwrap(negi_sensme_analyzer_create())
        defer { negi_sensme_analyzer_destroy(analyzer) }
        write(item, to: analyzer, stopAtSaturation: true)
        XCTAssertEqual(negi_sensme_analyzer_needs_pcm(analyzer), 0)
        var summary = NegiSensMeAnalyzerSummary()
        let size = negi_sensme_analyzer_finish(analyzer, nil, 0, &summary)
        XCTAssertEqual(size, item.encodedBytes)
        XCTAssertLessThan(summary.input_frames, UInt64(item.frames))
        var bytes = [UInt8](repeating: 0, count: size)
        XCTAssertEqual(negi_sensme_analyzer_finish(analyzer, &bytes, size, nil), size)
        XCTAssertEqual(SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(), item.encodedSHA256)
    }

    func testCompleteGeneratedPCMMatchesOriginalEngine() throws {
        let fixture = try load()
        XCTAssertEqual(fixture.dispatchFrames, 4096); XCTAssertEqual(fixture.cases.count, 23)
        for (index, item) in fixture.cases.enumerated() {
            let analyzer = try XCTUnwrap(negi_sensme_analyzer_create())
            defer { negi_sensme_analyzer_destroy(analyzer) }
            XCTAssertEqual(negi_sensme_analyzer_needs_pcm(analyzer), 1)
            write(item, to: analyzer)
            var summary = NegiSensMeAnalyzerSummary()
            let size = negi_sensme_analyzer_finish(analyzer, nil, 0, &summary)
            XCTAssertEqual(size, item.encodedBytes, "case \(index)")
            XCTAssertEqual(summary.input_frames, UInt64(item.frames))
            XCTAssertEqual(summary.leading_zero_frames, UInt64(item.kind == "silence" ? item.frames : item.leadingZeroFrames))
            XCTAssertEqual(summary.processed_frames, item.processedFrames)
            XCTAssertEqual(summary.is_short, item.processedFrames < 3802 ? 1 : 0)
            XCTAssertEqual(summary.has_bpm, item.processedFrames < 3802 ? 0 : 1)
            if summary.is_short != 0 { XCTAssertEqual(summary.bpm, 0) }
            guard size == item.encodedBytes else { continue }
            var output = [UInt8](repeating: 0xa5, count: size + 16)
            XCTAssertEqual(negi_sensme_analyzer_finish(analyzer, &output, size, nil), size)
            let hash = SHA256.hash(data: Data(output.prefix(size))).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, item.encodedSHA256, "case \(index)")
            XCTAssertEqual(Array(output.suffix(16)), [UInt8](repeating: 0xa5, count: 16))
            XCTAssertEqual(negi_sensme_analyzer_needs_pcm(analyzer), 0)
            XCTAssertEqual(negi_sensme_analyzer_write(analyzer, [1, -1], 1), 0)
        }
    }

    func testInvalidCallsAndCapacityFailureRetainCallerStorage() throws {
        let analyzer = try XCTUnwrap(negi_sensme_analyzer_create())
        defer { negi_sensme_analyzer_destroy(analyzer) }
        var summary = NegiSensMeAnalyzerSummary(); summary.input_frames = 99
        var output = [UInt8](repeating: 0xa5, count: 512)
        XCTAssertEqual(negi_sensme_analyzer_finish(analyzer, &output, 512, &summary), 0)
        XCTAssertEqual(summary.input_frames, 99)
        XCTAssertEqual(negi_sensme_analyzer_write(nil, [1, -1], 1), 0)
        XCTAssertEqual(negi_sensme_analyzer_write(analyzer, nil, 1), 0)
        XCTAssertEqual(negi_sensme_analyzer_write(analyzer, [1, -1], 65537), 0)
        XCTAssertEqual(negi_sensme_analyzer_write(analyzer, nil, 0), 1)
        let input: [Int16] = [1, -1]
        XCTAssertEqual(negi_sensme_analyzer_write(analyzer, input, 1), 1)
        XCTAssertEqual(input, [1, -1])
        XCTAssertEqual(negi_sensme_analyzer_finish(analyzer, &output, 1, &summary), 0)
        XCTAssertEqual(output, [UInt8](repeating: 0xa5, count: 512)); XCTAssertEqual(summary.input_frames, 99)
        let size = negi_sensme_analyzer_finish(analyzer, nil, 0, &summary)
        XCTAssertEqual(size, 310); XCTAssertEqual(summary.input_frames, 1); XCTAssertEqual(summary.has_bpm, 0)
        XCTAssertEqual(negi_sensme_analyzer_finish(analyzer, &output, size, &summary), size)
        XCTAssertEqual(negi_sensme_analyzer_finish(nil, &output, size, &summary), 0)
        negi_sensme_analyzer_destroy(nil)
    }
}
