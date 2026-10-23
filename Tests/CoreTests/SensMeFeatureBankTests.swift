import XCTest
import CryptoKit
import CSensMeCore

private final class FeatureFrames {
    var bytes = Data()
    var count = 0
    var stopAfter: Int?
}

private let collectFeatureFrame: NegiSensMeFeatureCallback = { context, frame in
    guard let context, let frame else { return 0 }
    let value = Unmanaged<FeatureFrames>.fromOpaque(context).takeUnretainedValue()
    value.bytes.append(UnsafeRawPointer(frame).assumingMemoryBound(to: UInt8.self), count: 144)
    value.count += 1
    if let limit = value.stopAfter, value.count >= limit { return 0 }
    return 1
}

final class SensMeFeatureBankTests: XCTestCase {
    private struct DefaultCase: Decodable {
        let kind, sha256, postStartupSHA256: String
        let inputFrames, rawFrames, startupFrames: Int
    }
    private struct DefaultFixtures: Decodable { let partition: [Int]; let cases: [DefaultCase] }
    private func tones() -> [Int16] {
        var seed: UInt32 = 0x39FA1234
        return (0..<12*47).map { i in
            seed = 1664525 &* seed &+ 1013904223
            let value = Int(Int16(bitPattern: UInt16(seed >> 16))) / 16
            return Int16(value + (i % 47 == 23 ? 12000 : 0))
        }
    }
    private func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testRawEnergyFramesAgainstAuditedSonyWithSelfGeneratedToneTaps() throws {
        // Actual DLL executions with self-generated taps, no Sony tone table or
        // music in the test. Raw frames include startup alignment and smoothing.
        let fixtures: [(String, String, String)] = [
            ("random", "eb2df8bb7a827889f727de912f598069b25acdd8812c31485203b42e184f32ea", "56710d45038baf6a4274f0c7dc8a95c04155f18b9cc400291e77fede84fd8f93"),
            ("impulse", "7ff4ae06f6b04f86aeebf1e925bb2d9914bae878c8994826534e85b54bb1f63c", "e621a87088407bac3b7775f7cc9179b6bf29bd0d3373bb49742bfeee01a7cac8"),
            ("silence", "d4c5200692be83fb73fcb2b3ae0cde724c900b311c0c428f80892bbbc7507c8b", "3517ca9634183cb9973ef44bed646c156956c08f9a3d139fe8eb804b0ffdc35b"),
            ("limits", "93fd4873addf1b9b7cdf213c34bcda813ca34899346e0953f8aacc39f5128925", "07a2dc6f36c24cd49983d8dfe525c75e73cd9b52b103ff36a94f51c531789c26")
        ]
        try verify(fixtures, sampleCount: 262144, expectedFrames: 754, partition: [1, 3, 7, 13, 4096, 1, 5, 127])
    }

    func test100SecondFixedDispatchAgainstAuditedSonyWithSelfGeneratedToneTaps() throws {
        let fixtures: [(String, String, String)] = [
            ("random", "f9bcb2176830f9f88053ede85731bc1792406d561f9beb3ee12f85fb6411df7a", "f8b24886961ec9764801226dc64836d5c9169141e197f7f832a856bbd3e9e52f"),
            ("impulse", "022ab4d691e432932e0abcf78db9fd46abe938acab08a5658af1121621e9d5cf", "db24c0b8c2a23fd8c9c7f2a5b7a8087cdc91aadf944adf01cf560a08b253f659"),
            ("silence", "d12805627b8fe86a54b6bdec28b1ca4b092c18fdeabdae198a65e93bc3f43f98", "1dd07390d290b4189d189fe8dac3c9b8122d6eb5fb5ce4b04f83ed1567b3c2ae"),
            ("limits", "cb865166cafc0e15790c5af32af89fde56cc96305cb08bba751d75a672655e8b", "43831675a8af41cfb2f0b12d0bcbafe7758f36041387d99aa8730f9a52cac2db")
        ]
        try verify(fixtures, sampleCount: 4410000, expectedFrames: 12708, partition: [4096])
    }

    func testEmbeddedDefaultBankAgainstOriginalSyntheticFrames() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeDefaultBank", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(DefaultFixtures.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.cases.count, 8)
        for fixture in fixtures.cases {
            XCTAssertEqual(fixture.startupFrames, 292)
            try verify([(fixture.kind, fixture.sha256, fixture.postStartupSHA256)], sampleCount: fixture.inputFrames,
                expectedFrames: fixture.rawFrames, partition: fixtures.partition, defaultBank: true)
        }
        XCTAssertNil(negi_sensme_features_create_default(nil, nil))
    }

    private func verify(_ fixtures: [(String, String, String)], sampleCount: Int,
                        expectedFrames: Int, partition: [Int], defaultBank: Bool = false) throws {
        XCTAssertEqual(negi_sensme_features_startup_frames(), 292)
        let coefficients = tones()
        for (kind, expectedRaw, expectedPostStartup) in fixtures {
            var seed: UInt32 = 0x39C0FFEE
            let samples: [Int16] = (0..<sampleCount).map { i in
                seed = 1664525 &* seed &+ 1013904223
                switch kind {
                case "impulse": return i == 0 ? -32768 : 0
                case "silence": return 0
                case "limits": return [-32768, 32767, -1, 0, 1][i % 5]
                default: return Int16(bitPattern: UInt16(seed >> 16))
                }
            }
            let output = FeatureFrames()
            let state: OpaquePointer
            if defaultBank {
                state = try XCTUnwrap(negi_sensme_features_create_default(collectFeatureFrame, Unmanaged.passUnretained(output).toOpaque()))
            } else {
                state = try XCTUnwrap(coefficients.withUnsafeBufferPointer {
                    negi_sensme_features_create($0.baseAddress, collectFeatureFrame, Unmanaged.passUnretained(output).toOpaque())
                })
            }
            defer { negi_sensme_features_destroy(state) }
            samples.withUnsafeBufferPointer { input in
                var at = 0, part = 0
                while at < input.count {
                    let count = min(partition[part % partition.count], input.count - at)
                    XCTAssertEqual(negi_sensme_features_write(state, input.baseAddress!.advanced(by: at), count), 1)
                    at += count; part += 1
                }
            }
            XCTAssertEqual(output.count, expectedFrames, kind)
            XCTAssertEqual(sha(output.bytes), expectedRaw, kind)
            XCTAssertEqual(sha(Data(output.bytes.dropFirst(292*144))), expectedPostStartup, kind)
        }
    }

    func testCallbackCancellationAndInputBounds() throws {
        let coefficients = tones(), output = FeatureFrames()
        output.stopAfter = 1
        let state = try XCTUnwrap(coefficients.withUnsafeBufferPointer {
            negi_sensme_features_create($0.baseAddress, collectFeatureFrame, Unmanaged.passUnretained(output).toOpaque())
        })
        defer { negi_sensme_features_destroy(state) }
        XCTAssertEqual(negi_sensme_features_write(state, nil, 0), 1)
        XCTAssertEqual(negi_sensme_features_write(state, nil, 4097), 0)
        XCTAssertEqual(output.count, 0)
        let input: [Int16] = Array(repeating: 1000, count: 4096)
        XCTAssertEqual(input.withUnsafeBufferPointer { negi_sensme_features_write(state, $0.baseAddress, $0.count) }, 0)
        XCTAssertEqual(output.count, 1)
        // Cancellation makes this instance terminal; it cannot emit more frames.
        XCTAssertEqual(input.withUnsafeBufferPointer { negi_sensme_features_write(state, $0.baseAddress, $0.count) }, 0)
        XCTAssertEqual(output.count, 1)
    }
}
