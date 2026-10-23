import XCTest
import CryptoKit
import CSensMeCore

final class SensMeSpectralStatsTests: XCTestCase {
    private func input() -> [UInt16] {
        var seed: UInt32 = 0x39CF1234
        var words: [UInt16] = []
        for frame in 0..<1024 {
            for bin in 0..<72 {
                seed = 1664525 &* seed &+ 1013904223
                let value: UInt16
                if frame < 128 { value = 0 }
                else if frame < 256 { value = frame == 128 && bin % 12 == 0 ? 65535 : 0 }
                else if frame < 512 { value = UInt16(seed >> 16) }
                else if frame < 768 { value = UInt16((frame*73 + bin*911) % 65536) }
                else { value = [0, 1, 2, 1024, 65535][(frame + bin) % 5] }
                words.append(value)
            }
        }
        return words
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testBothMonoProfilesAgainstAuditedIntermediateAndSummaryHashes() throws {
        // Captured from actual audited DLL executions with self-generated
        // zero, impulse, random, ramp and extreme energy frames. No music or
        // private reference files are required to execute this regression.
        let fixtures: [(Int32, String, String, String)] = [
            (1, "ac9691cf2362a2dbe51e8c5ab0cdc22dcad3bf98c8bfb61c8559f361b28bc62e", "491102ffeab7d9bbad3c108e53d749bf9fdaaffb253ccb181b62ea4e529eeb46", "c34e5e88667e6299513e448c7ebde86e5c8be8c228bba6fc1874ae359d01bdfb"),
            (0, "0d859d1da7eb620487ba96684e8d69603b9ce9b1d9d917b4f524a1388a93994b", "a3838ad412c73a8244e77158763e36168a93d0e9152a1b35cb5addb91b6da33f", "ade4caffc296057f6e6507ae7d980cd9a38c8d4c8ee548e105e2378b4be3810e")
        ]
        let energy = input()
        for (mode, expectedSeries, expectedSummary, expectedTrack) in fixtures {
            let state = try XCTUnwrap(negi_sensme_spectral_create(mode))
            defer { negi_sensme_spectral_destroy(state) }
            var seriesBytes = Data(), summaryBytes = Data()
            var blocks: [Float] = []
            energy.withUnsafeBufferPointer { source in
                for block in 0..<8 {
                    var means = [Float](repeating: 0, count: 16)
                    var deviations = means
                    var series = [Float](repeating: 0, count: 16*128)
                    XCTAssertEqual(negi_sensme_spectral_block(state, source.baseAddress!.advanced(by: block*128*72), &means, &deviations, &series), 1)
                    series.withUnsafeBytes { seriesBytes.append(contentsOf: $0) }
                    means.withUnsafeBytes { summaryBytes.append(contentsOf: $0) }
                    deviations.withUnsafeBytes { summaryBytes.append(contentsOf: $0) }
                    blocks.append(contentsOf: means)
                    blocks.append(contentsOf: deviations)
                }
            }
            XCTAssertEqual(digest(seriesBytes), expectedSeries, "profile \(mode)")
            XCTAssertEqual(digest(summaryBytes), expectedSummary, "profile \(mode)")
            var track = [Float](repeating: 0, count: 64)
            XCTAssertEqual(negi_sensme_spectral_summary(&blocks, 8, &track), 1)
            XCTAssertEqual(digest(track.withUnsafeBytes { Data($0) }), expectedTrack, "profile \(mode)")
        }
    }

    func testTrackReductionEmptySinglePairAndInvalidInputs() {
        var output = [Float](repeating: -9, count: 64)
        XCTAssertEqual(negi_sensme_spectral_summary(nil, 1, &output), 0)
        XCTAssertEqual(output, Array(repeating: -9, count: 64))
        XCTAssertEqual(negi_sensme_spectral_summary(nil, 0, nil), 0)
        XCTAssertEqual(negi_sensme_spectral_summary(nil, 0, &output), 1)
        XCTAssertEqual(output, Array(repeating: 0, count: 64))
        var blocks = (0..<32).map { Float($0) }
        XCTAssertEqual(negi_sensme_spectral_summary(&blocks, Int.max, &output), 0)
        XCTAssertEqual(negi_sensme_spectral_summary(&blocks, 1, &output), 1)
        XCTAssertEqual(Array(output[0..<16]), Array(blocks[0..<16]))
        XCTAssertEqual(Array(output[16..<32]), Array(repeating: 0, count: 16))
        XCTAssertEqual(Array(output[32..<48]), Array(blocks[16..<32]))
        XCTAssertEqual(Array(output[48..<64]), Array(repeating: 0, count: 16))
        blocks.append(contentsOf: (0..<32).map { Float($0 + 2) })
        XCTAssertEqual(negi_sensme_spectral_summary(&blocks, 2, &output), 1)
        XCTAssertEqual(Array(output[0..<16]), (0..<16).map { Float($0 + 1) })
        XCTAssertEqual(Array(output[32..<48]), (16..<32).map { Float($0 + 1) })
        XCTAssertEqual(Array(output[16..<32]), Array(repeating: Float(2).squareRoot(), count: 16))
        XCTAssertEqual(Array(output[48..<64]), Array(repeating: Float(2).squareRoot(), count: 16))
    }

    func testInvalidInputsAndOptionalSeriesOnSilence() throws {
        XCTAssertNil(negi_sensme_spectral_create(-1))
        XCTAssertNil(negi_sensme_spectral_create(2))
        let state = try XCTUnwrap(negi_sensme_spectral_create(1))
        defer { negi_sensme_spectral_destroy(state) }
        var means = [Float](repeating: -9, count: 16), deviations = means
        XCTAssertEqual(negi_sensme_spectral_block(state, nil, &means, &deviations, nil), 0)
        XCTAssertEqual(means, Array(repeating: -9, count: 16))
        let energy = [UInt16](repeating: 0, count: 128*72)
        XCTAssertEqual(energy.withUnsafeBufferPointer { negi_sensme_spectral_block(state, $0.baseAddress, &means, &deviations, nil) }, 1)
        var expected = [Float](repeating: 0, count: 16)
        expected[3] = 1 // Mono correlation is defined as one in the audited path.
        XCTAssertEqual(means, expected)
        XCTAssertEqual(deviations, Array(repeating: 0, count: 16))
    }

    func testFinalVolumeOnConstantAmplitudesAndEmptyState() throws {
        let cases: [(UInt16, Float)] = [(0, 0), (1, 0), (4, 6), (16, 12), (256, 24)]
        for mode in [Int32(0), 1] {
            for (energy, expected) in cases {
                let state = try XCTUnwrap(negi_sensme_spectral_create(mode))
                defer { negi_sensme_spectral_destroy(state) }
                var output: Float = -123
                XCTAssertEqual(negi_sensme_spectral_volume(state, &output), 0)
                XCTAssertEqual(output, -123)
                let input = [UInt16](repeating: energy, count: 128*72)
                var means = [Float](repeating: 0, count: 16), deviations = means
                for _ in 0..<2 {
                    XCTAssertEqual(negi_sensme_spectral_block(state, input, &means, &deviations, nil), 1)
                    XCTAssertEqual(negi_sensme_spectral_volume(state, &output), 1)
                    XCTAssertEqual(output, expected)
                    XCTAssertEqual(negi_sensme_spectral_volume(state, &output), 1)
                    XCTAssertEqual(output, expected)
                }
                XCTAssertEqual(negi_sensme_spectral_volume(state, nil), 0)
            }
        }
        var output: Float = -123
        XCTAssertEqual(negi_sensme_spectral_volume(nil, &output), 0)
        XCTAssertEqual(output, -123)
    }
}
