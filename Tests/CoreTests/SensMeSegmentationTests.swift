import XCTest
import CryptoKit
import CSensMeCore

final class SensMeSegmentationTests: XCTestCase {
    private struct SectionFixture: Decodable {
        let kind, sectionKind, SHA256: String
        let count: Int
    }
    private struct SimilarityFixture: Decodable {
        let kind, vectorsSHA256, matrixSHA256: String
        let count: Int
        let unobservedVerified: Bool
    }
    private struct CoarseFixture: Decodable {
        let kind, labelsSHA256: String
        let count, phase, sectionCount: Int
    }
    private struct Fixtures<T: Decodable>: Decodable { let cases: [T] }
    private func load<T: Decodable>(_ name: String, _: T.Type) throws -> [T] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(Fixtures<T>.self, from: Data(contentsOf: url)).cases
    }
    private func digest<T>(_ input: [T]) -> String {
        input.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }

    private func sectionInput(_ fixture: SectionFixture) -> ([Int32], [Int32]) {
        var classes = [Int32](), sections = [Int32](), seed: UInt32 = 0x39ca7e11
        for i in 0..<fixture.count {
            seed = 1664525 &* seed &+ 1013904223
            let value: Int
            switch fixture.kind {
            case "zero": value = 0
            case "minor": value = 12
            case "ramp": value = i % 24
            case "random": value = Int(seed >> 16) % 24
            case "triad": value = [0, 4, 7, 12, 16, 19][i % 6]
            default: value = [0, 7, 5, 14, 17, 21, 9][i / 5 % 7]
            }
            let label: Int
            switch fixture.sectionKind {
            case "one": label = 0
            case "every7": label = i / 7
            case "alternating": label = i % 2 - 1
            default: label = [2, -1, 2, 3][i / 13 % 4]
            }
            classes.append(Int32(value)); sections.append(Int32(label))
        }
        return (classes, sections)
    }

    private func compressedTones(_ kind: String) -> [UInt16] {
        var seed: UInt32 = 0x39da7a11, result = [UInt16]()
        // Consume group 0 before generating group 1, as in the Python oracle.
        for _ in 0..<(19008 * 12) { seed = 1664525 &* seed &+ 1013904223 }
        for pair in 0..<19008 {
            for tone in 0..<12 {
                seed = 1664525 &* seed &+ 1013904223
                let value: Int
                switch kind {
                case "zero": value = 0
                case "constant": value = 12346
                case "random": value = Int(seed >> 16)
                case "triad": value = [0, 4, 7].contains(((tone - pair / 1000 - 1) % 12 + 12) % 12) ? 36000 : 1234
                default: value = 32768 + Int(seed >> 31)
                }
                result.append(UInt16(value))
            }
        }
        return result
    }

    private func coarseInput(_ fixture: CoarseFixture) -> ([UInt16], [Int32]) {
        let side = fixture.count / 2 - 1
        var matrix = [UInt16](repeating: 0, count: side * side), seed: UInt32 = 0x39ce7e11
        for row in 0..<side {
            for column in row..<side {
                seed = 1664525 &* seed &+ 1013904223
                let value: UInt16
                if row == column { value = 65535 }
                else {
                    switch fixture.kind {
                    case "diagonal": value = 0
                    case "plateau": value = 60000
                    case "periodic": value = (row - column) % 32 == 0 ? 60000 : 1000
                    case "three-types": value = row / 32 % 3 == column / 32 % 3 && row % 32 == column % 32 ? 60000 : 1000
                    case "dense": value = (row - column) % 2 == 0 ? 60000 : 1000
                    default: value = UInt16(seed >> 16)
                    }
                }
                matrix[row * side + column] = value; matrix[column * side + row] = value
            }
        }
        return (matrix, (0..<fixture.count).map { Int32(($0 + fixture.phase) % 4 + 1) })
    }

    func testSegmentRootProbabilitiesMatchAuditedEngine() throws {
        let fixtures = try load("SensMeSectionKey", SectionFixture.self)
        XCTAssertEqual(fixtures.count, 72); XCTAssertEqual(MemoryLayout<NegiSensMeSectionKey>.size, 52)
        for fixture in fixtures {
            let (classes, sections) = sectionInput(fixture)
            var output = [NegiSensMeSectionKey](repeating: .init(), count: fixture.count)
            XCTAssertEqual(negi_sensme_section_keys(classes, sections, fixture.count, &output), 1)
            XCTAssertEqual(digest(output), fixture.SHA256, "\(fixture.kind) \(fixture.sectionKind) \(fixture.count)")
        }
    }

    func testInvalidSectionInputAndEmptySequence() {
        XCTAssertEqual(negi_sensme_section_keys(nil, nil, 0, nil), 1)
        var output = [NegiSensMeSectionKey](repeating: .init(), count: 2)
        output[0].root = -7; let before = digest(output)
        for values: [Int32] in [[0, 24], [0, -1]] {
            XCTAssertEqual(negi_sensme_section_keys(values, [0, 0], 2, &output), 0)
            XCTAssertEqual(digest(output), before)
        }
        XCTAssertEqual(negi_sensme_section_keys([0], [0], 961, &output), 0)
        XCTAssertEqual(negi_sensme_section_keys(nil, [0], 1, &output), 0)
    }

    func testDescriptorsAndSimilarityMatchObservedSyntheticInputs() throws {
        let fixtures = try load("SensMeSimilarity", SimilarityFixture.self)
        XCTAssertEqual(fixtures.count, 30)
        var kind = "", tones = [UInt16]()
        for fixture in fixtures {
            XCTAssertTrue(fixture.unobservedVerified)
            if fixture.kind != kind { kind = fixture.kind; tones = compressedTones(kind) }
            let times = (0..<fixture.count).map { Float(31.25 + Double($0 * (fixture.count > 480 ? 250 : 500))) }
            let groups = fixture.count / 2
            var vectors = [Float](repeating: 0, count: groups * 12)
            var matrix = [UInt16](repeating: 0, count: (groups - 1) * (groups - 1))
            XCTAssertEqual(negi_sensme_segment_vectors(tones, 19008, times, fixture.count, &vectors), 1)
            XCTAssertEqual(digest(vectors), fixture.vectorsSHA256, "\(kind) \(fixture.count)")
            XCTAssertEqual(negi_sensme_similarity_matrix(vectors, groups, &matrix), 1)
            XCTAssertEqual(digest(matrix), fixture.matrixSHA256, "\(kind) \(fixture.count)")
        }
    }

    func testInvalidSimilarityInputLeavesMatrixUnchanged() {
        var output: [UInt16] = [1234]
        for value: Float in [.nan, -.infinity, -1, 3] {
            var input = [Float](repeating: 1, count: 24); input[23] = value
            XCTAssertEqual(negi_sensme_similarity_matrix(input, 2, &output), 0)
            XCTAssertEqual(output, [1234])
        }
        XCTAssertEqual(negi_sensme_similarity_matrix([Float](repeating: 0, count: 12), 1, nil), 1)
        XCTAssertEqual(negi_sensme_similarity_matrix(nil, 2, &output), 0)
        XCTAssertEqual(negi_sensme_similarity_matrix([0], 481, &output), 0)
    }

    func testDescriptorExtentValidationBeforeWriting() {
        let tones: [UInt16] = [UInt16](repeating: 1, count: 12)
        var output = [Float](repeating: -7, count: 24)
        for (pairs, times): (Int, [Float]) in [(1, [0, 500]), (0, [0, 500]),
            (38017, [0, 500]), (1, [.nan, 500]), (1, [0, 1, -1, 2])] {
            XCTAssertEqual(negi_sensme_segment_vectors(tones, pairs, times, times.count, &output), 0)
            XCTAssertEqual(output, [Float](repeating: -7, count: 24))
        }
    }

    func testRepeatedSectionsAgainstGeneratedPeakRidges() throws {
        let fixtures = try load("SensMeCoarseSections", CoarseFixture.self)
        XCTAssertEqual(fixtures.count, 48)
        for fixture in fixtures {
            let (matrix, numbers) = coarseInput(fixture), before = digest(matrix)
            var output = [Int32](repeating: -7, count: fixture.count), types = 999
            XCTAssertEqual(negi_sensme_coarse_sections(matrix, fixture.count, numbers, &output, &types), 1)
            XCTAssertEqual(types, fixture.sectionCount)
            XCTAssertEqual(digest(output), fixture.labelsSHA256, "\(fixture.kind) \(fixture.count) phase \(fixture.phase)")
            XCTAssertEqual(digest(matrix), before)
        }
    }

    func testInvalidCoarseInputLeavesOutputsUnchanged() {
        var output: [Int32] = [-7, -7, -7, -7], types = 999
        for numbers: [Int32] in [[1, 2, 0, 4], [1, 2, 5, 4]] {
            XCTAssertEqual(negi_sensme_coarse_sections([65535], 4, numbers, &output, &types), 0)
            XCTAssertEqual(output, [-7, -7, -7, -7]); XCTAssertEqual(types, 999)
        }
        XCTAssertEqual(negi_sensme_coarse_sections(nil, 4, [1, 2, 3, 4], &output, &types), 0)
        XCTAssertEqual(negi_sensme_coarse_sections([65535], 961, [1], &output, &types), 0)
    }
}
