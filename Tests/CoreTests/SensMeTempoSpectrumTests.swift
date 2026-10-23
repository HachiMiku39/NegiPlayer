import XCTest
import CryptoKit
import CSensMeCore

final class SensMeTempoSpectrumTests: XCTestCase {
    private struct Fixture: Decodable {
        let kind, profileSHA256: String
        let segments: Int
        let spreadBits: UInt32
    }
    private struct Fixtures: Decodable {
        let cases: [Fixture]
        let impulseProfilesSHA256: String
    }
    private func fixtures() throws -> Fixtures {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeTempoSpectrum", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
    private func digest(_ values: [Float]) -> String {
        values.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }

    func testAllOriginalLogarithmicBinAssignments() throws {
        let expected = try fixtures().impulseProfilesSHA256
        var hasher = SHA256()
        for bin in 1..<2048 {
            var spectrum = [Float](repeating: 0, count: 2049)
            var profile = [Float](repeating: 0, count: 256)
            spectrum[bin] = 1
            XCTAssertEqual(negi_sensme_tempo_spectrum_accumulate(spectrum, &profile), 1)
            profile.withUnsafeBytes { hasher.update(data: Data($0)) }
        }
        XCTAssertEqual(hasher.finalize().map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testSpectrumAccumulationAndSpreadAgainstOriginalHelper() throws {
        let cases = try fixtures().cases
        XCTAssertEqual(cases.count, 21)
        for fixture in cases {
            var seed: UInt32 = 0x39c02746
            var profile = [Float](repeating: 0, count: 256)
            for _ in 0..<fixture.segments {
                var spectrum = [Float]()
                for bin in 0..<2049 {
                    seed = 1664525 &* seed &+ 1013904223
                    var value = Double(seed >> 16 & 65535)/64
                    switch fixture.kind {
                    case "zero": value = 0
                    case "constant": value = 1
                    case "sparse": if bin % 53 != 0 { value = 0 }
                    case "low": if bin > 32 { value = 0 }
                    case "high": if bin < 2000 { value = 0 }
                    case "wide": value *= pow(2, Double(bin % 31 - 15))
                    default: break
                    }
                    spectrum.append(Float(value))
                }
                XCTAssertEqual(negi_sensme_tempo_spectrum_accumulate(spectrum, &profile), 1)
            }
            XCTAssertEqual(digest(profile), fixture.profileSHA256, "\(fixture.kind) \(fixture.segments)")
            var result: Float = -1
            XCTAssertEqual(negi_sensme_tempo_spectrum_spread(profile, &result), 1)
            XCTAssertEqual(result.bitPattern, fixture.spreadBits, "\(fixture.kind) \(fixture.segments)")
        }
    }

    func testInvalidInputDoesNotChangeOutput() {
        var profile = [Float](repeating: 1, count: 256)
        var spectrum = [Float](repeating: 1, count: 2049)
        let initial = profile
        spectrum[2047] = .infinity
        XCTAssertEqual(negi_sensme_tempo_spectrum_accumulate(spectrum, &profile), 0)
        XCTAssertEqual(profile, initial)
        spectrum[2047] = -1
        XCTAssertEqual(negi_sensme_tempo_spectrum_accumulate(spectrum, &profile), 0)
        XCTAssertEqual(profile, initial)
        XCTAssertEqual(negi_sensme_tempo_spectrum_accumulate(nil, &profile), 0)
        XCTAssertEqual(negi_sensme_tempo_spectrum_accumulate(spectrum, nil), 0)
        var result: Float = -7
        profile[255] = .nan
        XCTAssertEqual(negi_sensme_tempo_spectrum_spread(profile, &result), 0)
        XCTAssertEqual(result, -7)
        profile[255] = -1
        XCTAssertEqual(negi_sensme_tempo_spectrum_spread(profile, &result), 0)
        XCTAssertEqual(result, -7)
        XCTAssertEqual(negi_sensme_tempo_spectrum_spread(nil, &result), 0)
        XCTAssertEqual(negi_sensme_tempo_spectrum_spread(initial, nil), 0)
        profile = [Float](repeating: .greatestFiniteMagnitude, count: 256)
        spectrum = [Float](repeating: .greatestFiniteMagnitude, count: 2049)
        XCTAssertEqual(negi_sensme_tempo_spectrum_accumulate(spectrum, &profile), 0)
        XCTAssertEqual(profile, Array(repeating: .greatestFiniteMagnitude, count: 256))
        XCTAssertEqual(negi_sensme_tempo_spectrum_spread(profile, &result), 0)
        XCTAssertEqual(result, -7)
    }
}
