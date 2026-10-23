import XCTest
import CryptoKit
import CSensMeCore

final class SensMeNativeCoreTests: XCTestCase {
    private func prepare(_ samples: [Int16], channels: UInt32, state: inout NegiSensMePCMState) -> [Int16] {
        var output = [Int16](repeating: 0, count: samples.count)
        let count = samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                negi_sensme_prepare_pcm(&state, input.baseAddress, samples.count / Int(channels), channels, out.baseAddress)
            }
        }
        return Array(output.prefix(count))
    }

    func testLeadingSilenceAcrossChunksAndAntiPhase() {
        var state = NegiSensMePCMState(leading_zero_frames: 0, has_signal: 0)
        XCTAssertEqual(prepare([0, 0, 0, 0], channels: 2, state: &state), [])
        // Signal detection precedes mono summation. Anti-phase audio is not trimmed.
        XCTAssertEqual(prepare([0, 0, 100, -100, 0, 0, -1, 0, -32768, 32767], channels: 2, state: &state), [0, 0, -1, -1])
        XCTAssertEqual(state.leading_zero_frames, 3)
        XCTAssertEqual(prepare([0, 0], channels: 2, state: &state), [0])
        var mono = NegiSensMePCMState(leading_zero_frames: 0, has_signal: 0)
        XCTAssertEqual(prepare([0, -32768, 32767, 0], channels: 1, state: &mono), [-32768, 32767, 0])
    }

    func testEmptyInvalidAndInPlacePCM() {
        var state = NegiSensMePCMState(leading_zero_frames: 0, has_signal: 0)
        XCTAssertEqual(negi_sensme_prepare_pcm(&state, nil, 0, 2, nil), 0)
        XCTAssertEqual(negi_sensme_prepare_pcm(&state, nil, 1, 2, nil), -1)
        XCTAssertEqual(negi_sensme_prepare_pcm(&state, nil, 0, 3, nil), -1)
        XCTAssertEqual(state.leading_zero_frames, 0)
        var samples: [Int16] = [0, 0, 32767, 32767, -32768, -32768, -2, -1]
        let count = samples.withUnsafeMutableBufferPointer { p in
            negi_sensme_prepare_pcm(&state, p.baseAddress, 4, 2, p.baseAddress)
        }
        XCTAssertEqual(Array(samples.prefix(count)), [32767, -32768, -2])
    }

    func testIntegerFIRAgainstSonySyntheticOracle() throws {
        // Owner-supplied MMLib11 1.1.02.0640, SHA256 884ecce2...29a04,
        // internal integer FIR RVA 0x24b80. No Sony code, taps or music fixture.
        // These hashes were obtained by executing the audited function, not by
        // calculating expected values with this native implementation.
        let fixtures: [(Int, String, String, String)] = [
            (47, "random", "ab9863cb54c643ba7e489697ae1ef6ff3d21f7d991ce6b056f1c8d096875f797", "0773b3e586b2256a726cd81f78de36db95a688e5d7fb0ea5f8213293d9cd0f82"),
            (47, "impulse", "d0bbefea3103b9b3143bc5f430eba9ff266bb71e8afa570e1cc700af9bca4566", "b06a694e163756851745341bdbc1729b738f6730d92fdc22c3241ad700dab67d"),
            (47, "limits", "4550aa8baa8c15c16581c12a5d81632ed01799b962e428bf06db356b36d633ca", "7708266816527831ef47819190af51ebff1fa1772628df5409e6ccd7ec45064a"),
            (47, "overflow", "013d6ba74fe07926b05d4bc397c0ccfce813c2f6c8f4c676ea0ead1d1bb7c03a", "05bc9ce65f21ac5f7143ffe72f51a14b418775644a461398a715e22e957b3dff"),
            (256, "random", "94f77fb666c785063f97871c0850d1d443bf7ea3b1da8ab405b58856263d7045", "8948fb0c8ac584b823e966fae6a5345b7b2f4bae9eef1daabc74c0bd06372efa"),
            (256, "impulse", "6277119b3f632eed4e8829ced99f45b5a44b9d08a7e8319da33c4244ca030493", "06b4ea124be464c5f51015ffd90385f1f9668f233158734a95ac821f6e0a9c19"),
            (256, "limits", "4485cf33f7cac55fe13c154decf73999e86e416b9f4782765b118e0f10d134bf", "9999eeb6995bc68d58706948a21f2cd25d49dbf720d2182391c8b2d55246c775"),
            (256, "overflow", "e0707d0778981c71af58037816fd6d7c13d744c9a10a430d62529f84bdf3f8af", "d2b7b58599489088ca0b6fab779bf6b8a12c0299261ea0372d0ffc4eeeb6d357")
        ]
        for (taps, kind, fullDigest, decimatedDigest) in fixtures {
            var seed: UInt32 = 0x39C0FFEE
            func next() -> Int16 {
                seed = 1664525 &* seed &+ 1013904223
                return Int16(bitPattern: UInt16(seed >> 16))
            }
            var coefficients = (0..<taps).map { _ in next() }
            let samples: [Int16] = (0..<65536).map { i in
                let random = next()
                switch kind {
                case "impulse": return i == 0 ? -32768 : 0
                case "limits": return [-32768, 32767, -1, 0, 1][i % 5]
                case "overflow": return -32768
                default: return random
                }
            }
            if kind == "overflow" { coefficients = Array(repeating: -32768, count: taps) }
            let filter = try XCTUnwrap(coefficients.withUnsafeBufferPointer { negi_sensme_fir_create($0.baseAddress, taps) })
            defer { negi_sensme_fir_destroy(filter) }
            func digest(decimated: Bool) -> String {
                var data = Data()
                for (i, sample) in samples.enumerated() {
                    if decimated && i % 2 != 0 { negi_sensme_fir_feed(filter, sample); continue }
                    var word = negi_sensme_fir_push(filter, sample).littleEndian
                    withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
                }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            XCTAssertEqual(digest(decimated: false), fullDigest, "\(taps) \(kind)")
            negi_sensme_fir_reset(filter)
            XCTAssertEqual(digest(decimated: true), decimatedDigest, "\(taps) \(kind) reset/feed")
        }
    }

    func testAnalysisResamplerAgainstSonySyntheticOracle() throws {
        let fixtures: [(Double, Int, String)] = [
            (44100/7040, 41848, "67f7903dfa21372708441ee9e1a0b7ddf2373d8dbdf1c4bdac1828f6122db4c7"),
            (48000/7040, 38448, "938edb42d0fd3b653c54cbcf1f0a88e7d67301f022adbbeb69b9433471162ba0"),
            (96000/7040, 19224, "d903bdc47b1869aacd69c1ca37f8b70c7275ea8763333833ab6beea0d79f464f"),
            (192000/7040, 9612, "a3261e3bd67ecc0845a1473db3f65ca08db6b76f51efc27b6ac4a18ed86fb799"),
            (6, 43691, "e9457a78916ffd77e497c6782b76f49a7cdca6851f4a8733126006c50af2adc5"),
            (1.5, 174762, "5e95a7a90665af10abe989d2406e52d3ec1ff9cdd31f7d6543bab41b59aa235b"),
            (1, 262144, "fced0a69d98a37a641993bf85ee56b3057dc482783302c4d8b44abebd9046251"),
            (0.75, 349525, "1070d976f1cb191ea12bab6a6bef891a04c7ba665308c1f7d0f0155bc76659e7")
        ]
        var seed: UInt32 = 0x39C0FFEE
        let input: [Float] = (0..<262144).map { i in
            seed = 1664525 &* seed &+ 1013904223
            return Float(i % 256 == 0 ? Int16.min : Int16(bitPattern: UInt16(seed >> 16))) / 32768
        }
        for (ratio, outputFrames, expected) in fixtures {
            let state = try XCTUnwrap(negi_sensme_resampler_create(ratio))
            defer { negi_sensme_resampler_destroy(state) }
            var bytes = Data(), frames = 0, at = 0, part = 0
            let partition = [1, 3, 7, 13, 4097, 1, 5, 127]
            input.withUnsafeBufferPointer { source in
                while at < source.count {
                    let count = min(partition[part % partition.count], source.count - at)
                    XCTAssertEqual(negi_sensme_resampler_write(state, source.baseAddress!.advanced(by: at), count), 1)
                    let available = negi_sensme_resampler_available(state)
                    if available > 0 {
                        var output = [Float](repeating: 0, count: available)
                        XCTAssertEqual(output.withUnsafeMutableBufferPointer { negi_sensme_resampler_read(state, $0.baseAddress, available) }, 1)
                        // All supported Apple targets are little endian, as is the oracle.
                        output.withUnsafeBytes { bytes.append(contentsOf: $0) }
                        frames += available
                    }
                    at += count; part += 1
                }
            }
            XCTAssertEqual(frames, outputFrames)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected, "ratio \(ratio)")
        }
    }

    func testAnalysisResamplerPendingFramesResetAndRejectedWrites() throws {
        for ratio in [Double.nan, Double.infinity, 0, -1, 8192] {
            XCTAssertNil(negi_sensme_resampler_create(ratio))
        }
        let state = try XCTUnwrap(negi_sensme_resampler_create(6))
        defer { negi_sensme_resampler_destroy(state) }
        XCTAssertEqual(negi_sensme_resampler_write(state, nil, 0), 1)
        let first: [Float] = [0.25, 0.5, 0.75]
        XCTAssertEqual(first.withUnsafeBufferPointer { negi_sensme_resampler_write(state, $0.baseAddress, $0.count) }, 1)
        var output: Float = -9
        XCTAssertEqual(negi_sensme_resampler_read(state, &output, 1), 0)
        XCTAssertEqual(output, 0)
        let rest: [Float] = [1, 0, 0, 0, 0]
        XCTAssertEqual(rest.withUnsafeBufferPointer { negi_sensme_resampler_write(state, $0.baseAddress, $0.count) }, 1)
        XCTAssertEqual(negi_sensme_resampler_read(state, &output, 1), 1)
        XCTAssertEqual(output, 0.625)
        negi_sensme_resampler_reset(state)
        XCTAssertEqual(negi_sensme_resampler_available(state), 0)
        let tooLarge = [Float](repeating: 1, count: 16384)
        XCTAssertEqual(tooLarge.withUnsafeBufferPointer { negi_sensme_resampler_write(state, $0.baseAddress, $0.count) }, 0)
        XCTAssertEqual(negi_sensme_resampler_available(state), 0)
        let complete = first + rest
        XCTAssertEqual(complete.withUnsafeBufferPointer { negi_sensme_resampler_write(state, $0.baseAddress, $0.count) }, 1)
        XCTAssertEqual(negi_sensme_resampler_read(state, &output, 1), 1)
        XCTAssertEqual(output, 0.625)
    }
}
