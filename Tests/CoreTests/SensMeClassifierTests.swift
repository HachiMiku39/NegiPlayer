import XCTest
import CSensMeCore

final class SensMeClassifierTests: XCTestCase {
    private struct Case: Decodable {
        let words, outputWords: [UInt32]
    }
    private struct Fixture: Decodable {
        let selectors: [UInt32]
        let cases: [Case]
    }

    func testAllModelsAgainstGeneratedOriginalEngineVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeClassifiers", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.selectors, Array(25...74).map(UInt32.init))
        XCTAssertEqual(fixture.cases.count, 160)
        for (index, input) in fixture.cases.enumerated() {
            XCTAssertEqual(input.words.count, 189)
            XCTAssertEqual(input.outputWords.count, 50)
            var features = NegiSensMeResultFeatures()
            withUnsafeMutableBytes(of: &features) { bytes in
                for (offset, word) in input.words.enumerated() {
                    bytes.storeBytes(of: word, toByteOffset: 4 * offset, as: UInt32.self)
                }
            }
            let before = withUnsafeBytes(of: features) { Data($0) }
            for (selector, expected) in zip(fixture.selectors, input.outputWords) {
                var output: Int32 = -123456
                XCTAssertEqual(negi_sensme_classification_score(&features, selector, &output), 1)
                XCTAssertEqual(UInt32(bitPattern: output), expected, "case \(index), selector \(selector)")
            }
            XCTAssertEqual(withUnsafeBytes(of: features) { Data($0) }, before)
        }
    }

    func testInvalidInputLeavesScoreUnchanged() {
        var features = NegiSensMeResultFeatures()
        var output: Int32 = -123456
        for selector in [UInt32(0), 24, 75, .max] {
            XCTAssertEqual(negi_sensme_classification_score(&features, selector, &output), 0)
            XCTAssertEqual(output, -123456)
        }
        XCTAssertEqual(negi_sensme_classification_score(nil, 25, &output), 0)
        XCTAssertEqual(output, -123456)
        XCTAssertEqual(negi_sensme_classification_score(&features, 25, nil), 0)
        for bpm in [Double.nan, .infinity, -.infinity] {
            withUnsafeMutableBytes(of: &features) {
                $0.storeBytes(of: bpm, toByteOffset: 0x2e0 - 0x10, as: Double.self)
            }
            XCTAssertEqual(negi_sensme_classification_score(&features, 25, &output), 0)
            XCTAssertEqual(output, -123456)
        }
    }
}
