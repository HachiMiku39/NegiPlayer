import XCTest
import CryptoKit
import CSensMeCore

final class SensMeFFTTests: XCTestCase {
    func testPackedFFTAgainst45AuditedSyntheticCases() throws {
        // Reference bytes come from the audited DLL and self-generated input.
        // No FFT library, music, or compatibility runtime is required.
        let fixtures: [(Int, [String])] = [
            (2, [
                "af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc",
                "b3f689962d5d23d2c4d34e32885e60cb9af0119e64bbf4ce2446694c45d9cdb9",
                "e5a5b5164ea5a9e5dcbf187b073b41be9d787f9ad52e6ca3a9d033636b49eb4f",
                "bd2acdf0ca123db32eb287a9aa4fc64ee0c5e75036c8d4d3ee8718d1b2609166",
                "22fa48bfe0b93b2191e6b9ce54a2eac14ea48759bca0ceae2f3e3d1d33ed0762",
            ]),
            (4, [
                "374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb",
                "356a6ba735f2d98596f649f5574430b433d2ca59195005e78cd107f1324d857f",
                "c6f82db5bc941b3b9b2d5800949211860f1d4469bb34cfeab5b45d83e61d6a44",
                "66a8ae2e5513399c84a810d25d20168da44ba8de59ba4053ec5892f92a018afd",
                "cafdc3be572b64944690e6d03701f57ac76861e8061477d4677a3be8c189ab35",
            ]),
            (8, [
                "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925",
                "d6b037c5d652f613cb336b606649eec7c6852d593da3d9494c9e2d271c2ab5da",
                "0390d20771732c7551da98d53b7e9341f2ded232c370ca68118aec9dd5c77a65",
                "3616fe45ddc85d39f301c823364a4163385eaf7335d090989a2d7b359e539cac",
                "935e27f5961e3c737b06547ca1ac8b9ff6262ea8629d1f16bc830e0f714b8f9a",
            ]),
            (16, [
                "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b",
                "fe6c2217c4a26ad6b756ee6275a256e8574c7891fd728b1af21672da72510992",
                "7c45560d7e0bf4117e8ada68c7b406b85fc1c9bb3af95869f4c338db920a6c6c",
                "362c101ba6cbf8226987dc4fffa6a6475c1ee4f57a34a71988b723656596af95",
                "8cb8420a2af0e0051d144bf109e0183c107530467800a2ef8599edd960b117e7",
            ]),
            (32, [
                "38723a2e5e8a17aa7950dc008209944e898f69a7bd10a23c839d341e935fd5ca",
                "686ea225c7f78cc421c5cddc6fe4ce2987776c34a63c751a0ef6f62bde10be21",
                "08cc3934bcd8b6a69852eb00da3f74249b92260b53ca9251974b01b315b0a174",
                "61d8b4cab6602ca40d0749b77d66ba8f88b99f87148c98b6c9fd7bdfccbf2d76",
                "c061ca92ca5163728844bf190393ede9e121adc5e48dde208fd2a8560fc9e533",
            ]),
            (64, [
                "5341e6b2646979a70e57653007a1f310169421ec9bdd9f1a5648f75ade005af1",
                "9cc4c215e1b9b4f79ad0695cb6a3447e5bcf1d52bdce94941461c62cca3149ea",
                "ea8d78a772c23b6e1c4af8065658234e76f89b7b6b84a0783e2f05f31fe578d4",
                "624d360dfedeb404683e231986173f0210eb9103a23d68c8e682317f41406ac3",
                "dd226c545baa31b34b5c4028f5c8dcaefefd23c26802caa4c5efddb0a250751e",
            ]),
            (256, [
                "5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef",
                "578d9ccd530922ce9d77b054fbf059d21676ee78ac03f3ef33f84c65fed0c8dd",
                "f05e42b3430c2e4dbb9c99a1efc6f0f55d9e49e63e59ff57ec4f0099ae4ee23c",
                "81fa1df40542b692c31a7e3078992f7bf333bdf1d7c39ee27f7741a1bf39d3b7",
                "0bcf48885882bbdb2bf711dbc55f2b0e44be476568ca00ce60e894fd77e2e183",
            ]),
            (1024, [
                "ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7",
                "705d7b44e7e3e519e55f91c72c2846aadd5e3d1498b13cfa48015ba3657d82ce",
                "04cbc539025cef986c7cc4515d92d361801be98d047c5faff9cefa1800fa0949",
                "6fb68c3a09d0702958d4a069d30f649eee1e672018bfb9fd84cbc6286becb4e9",
                "845d243192be9a9be91d99d38aa3f4cd252314f60d1789653d14e3c6b77bf299",
            ]),
            (4096, [
                "4fe7b59af6de3b665b67788cc2f99892ab827efae3a467342b3bb4e3bc8e5bfe",
                "7a6352718d14b8bf56bad251dc848ba45afcaa200b4ad8e19ea2fa41ddeb27f2",
                "09dae9dd3ebd02f35943e42b899aec5555142266e0fa83423c46055cd10bf779",
                "7a65acecef6b837c6d2db8adc97d5a8b1a84b004f3d0292e37b87fd35c18b72a",
                "082dbdf554a3b549388b8849072ce88656ec995f0907313a8ae6d713a0123a32",
            ]),
        ]
        for (count, hashes) in fixtures {
            let state = try XCTUnwrap(negi_sensme_fft_create(count))
            defer { negi_sensme_fft_destroy(state) }
            for (kind, expected) in hashes.enumerated() {
                var seed: UInt32 = 0x39F17E
                var input: [Float] = []
                for i in 0..<count {
                    seed = 1664525 &* seed &+ 1013904223
                    let value: Float
                    switch kind {
                    case 0: value = 0
                    case 1: value = i == 0 ? 1 : 0
                    case 2: value = Float(Int(seed >> 16) - 32768)/128
                    case 3: value = i % 2 == 1 ? 8192 : -8192
                    default: value = Float(i % 257 - 128)/64
                    }
                    input.append(value)
                }
                var output = [Float](repeating: 0, count: count)
                XCTAssertEqual(negi_sensme_fft_real(state, &input, &output), 1)
                let digest = SHA256.hash(data: output.withUnsafeBytes { Data($0) }).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, expected, "count \(count), kind \(kind)")
            }
        }
    }

    func testInvalidLengthsAndInPlaceTransform() throws {
        for count in [0, 1, 3, 8192, Int.max] { XCTAssertNil(negi_sensme_fft_create(count)) }
        let state = try XCTUnwrap(negi_sensme_fft_create(16))
        defer { negi_sensme_fft_destroy(state) }
        var input = (0..<16).map { Float($0) }
        var output = [Float](repeating: -9, count: 16)
        XCTAssertEqual(negi_sensme_fft_real(state, nil, &output), 0)
        XCTAssertEqual(output, Array(repeating: -9, count: 16))
        XCTAssertEqual(negi_sensme_fft_real(state, &input, nil), 0)
        XCTAssertEqual(negi_sensme_fft_real(state, &input, &output), 1)
        input.withUnsafeMutableBufferPointer { buffer in
            XCTAssertEqual(negi_sensme_fft_real(state, buffer.baseAddress, buffer.baseAddress), 1)
        }
        XCTAssertEqual(input, output)
    }

    func testSilentTempoSpectrumRetainsPreviousCandidateAndRefinesItsNeighborhood() {
        var packed = [Float](repeating: 0, count: 4096)
        var magnitudes = [Float](repeating: -9, count: 2049)
        XCTAssertEqual(negi_sensme_tempo_candidate(packed, &magnitudes), 0)
        XCTAssertEqual(negi_sensme_tempo_candidate_seeded(packed, &magnitudes, 601), 601)
        XCTAssertEqual(magnitudes, [Float](repeating: 0, count: 2049))
        packed[1202] = 1 // Bin 601 lies outside the coarse 128..<512 search.
        XCTAssertEqual(negi_sensme_tempo_candidate_seeded(packed, nil, 600), 601)
        XCTAssertEqual(negi_sensme_tempo_candidate_seeded(packed, nil, -1), -1)
        XCTAssertEqual(negi_sensme_tempo_candidate_seeded(packed, nil, 2048), -1)
    }
}
