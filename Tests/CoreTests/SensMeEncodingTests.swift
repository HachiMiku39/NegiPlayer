import XCTest
import CryptoKit
import CSensMeCore

final class SensMeEncodingTests: XCTestCase {
    private struct Case: Decodable {
        let feature, beats: Int
        let processedFrames, volumeBits, sampleOffset: UInt32
        let chorusType: Int32
        let chorusBeat, encodedBytes: Int
        let encodedSHA256: String
    }
    private struct Fixture: Decodable {
        let features: [[UInt32]]
        // Millisecond float bits, bar, beat, tonal class, key root, section.
        let beats: [[[Int64]]]
        let cases: [Case]
    }
    private struct Source {
        var features = NegiSensMeResultFeatures()
        var beats: [NegiSensMeBeat] = []
        var keys: [NegiSensMeSectionKey] = []
        var sections: [Int32] = []
    }
    private func load() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SensMeEncoding", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func source(_ fixture: Fixture, _ item: Case) -> Source {
        var result = Source()
        let words = fixture.features[item.feature]
        XCTAssertEqual(words.count, 189)
        withUnsafeMutableBytes(of: &result.features) { bytes in
            for (index, word) in words.enumerated() {
                bytes.storeBytes(of: word, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        for record in fixture.beats[item.beats] {
            var beat = NegiSensMeBeat(), key = NegiSensMeSectionKey()
            beat.milliseconds = Float(bitPattern: UInt32(record[0]))
            beat.bar = Int32(record[1]); beat.beat = Int32(record[2]); beat.tonal_class = Int32(record[3])
            key.root = Int32(record[4])
            result.beats.append(beat); result.keys.append(key); result.sections.append(Int32(record[5]))
        }
        return result
    }
    private func withInput(_ source: Source, _ item: Case, _ body: (inout NegiSensMeEncodedInput) -> Void) {
        var features = source.features
        withUnsafePointer(to: &features) { features in
            source.beats.withUnsafeBufferPointer { beats in
                source.keys.withUnsafeBufferPointer { keys in
                    source.sections.withUnsafeBufferPointer { sections in
                        var input = NegiSensMeEncodedInput(features: features, beats: beats.baseAddress,
                            keys: keys.baseAddress, sections: sections.baseAddress, count: beats.count,
                            processed_frames: item.processedFrames, volume: Float(bitPattern: item.volumeBits),
                            chorus_type: item.chorusType, chorus_beat: item.chorusBeat, sample_offset: item.sampleOffset)
                        body(&input)
                    }
                }
            }
        }
    }
    private func inputBytes(_ input: NegiSensMeEncodedInput) -> [Data] {
        var result = [Data(bytes: input.features!, count: MemoryLayout<NegiSensMeResultFeatures>.size)]
        if input.count > 0 {
            result.append(Data(bytes: input.beats!, count: input.count * MemoryLayout<NegiSensMeBeat>.stride))
            result.append(Data(bytes: input.keys!, count: input.count * MemoryLayout<NegiSensMeSectionKey>.stride))
            result.append(Data(bytes: input.sections!, count: input.count * MemoryLayout<Int32>.stride))
        }
        return result
    }

    func testDefaultChunksMatchOriginalGeneratedVectors() throws {
        let fixture = try load()
        XCTAssertEqual(fixture.cases.count, 185)
        for (index, item) in fixture.cases.enumerated() {
            withInput(source(fixture, item), item) { input in
                let before = inputBytes(input)
                let size = negi_sensme_encode_smfmf(&input, nil, 0)
                XCTAssertEqual(size, item.encodedBytes, "case \(index)")
                guard size == item.encodedBytes else { return }
                var bytes = [UInt8](repeating: 0xa5, count: size + 16)
                XCTAssertEqual(negi_sensme_encode_smfmf(&input, &bytes, size), size)
                let hash = SHA256.hash(data: Data(bytes.prefix(size))).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(hash, item.encodedSHA256, "case \(index)")
                XCTAssertEqual(Array(bytes.suffix(16)), [UInt8](repeating: 0xa5, count: 16))
                XCTAssertEqual(inputBytes(input), before)
            }
        }
    }

    func testCapacityFailureLeavesEntireDestinationUnchanged() throws {
        let fixture = try load(), item = fixture.cases[5]
        withInput(source(fixture, item), item) { input in
            let size = negi_sensme_encode_smfmf(&input, nil, 0)
            XCTAssertGreaterThan(size, 0)
            var bytes = [UInt8](repeating: 0xa5, count: size + 16)
            for capacity in [0, size - 1] {
                XCTAssertEqual(negi_sensme_encode_smfmf(&input, &bytes, capacity), 0)
                XCTAssertEqual(bytes, [UInt8](repeating: 0xa5, count: size + 16))
            }
        }
    }

    func testInvalidInputFailsBeforeWriting() throws {
        let fixture = try load(), item = try XCTUnwrap(fixture.cases.first { fixture.beats[$0.beats].count == 24 })
        let valid = source(fixture, item)
        var output = [UInt8](repeating: 0xa5, count: 128)
        XCTAssertEqual(negi_sensme_encode_smfmf(nil, &output, output.count), 0)
        for variant in 0..<26 {
            var source = valid
            switch variant {
            case 0: source.beats[0].milliseconds = .nan
            case 1: source.beats[0].milliseconds = -1
            case 2: source.beats[0].milliseconds = 300001
            case 3: source.beats[1].milliseconds = source.beats[0].milliseconds
            case 4: source.beats[0].bar = -1
            case 5: source.beats[0].bar = 65536
            case 6: source.beats[0].beat = 0
            case 7: source.beats[0].beat = 5
            case 8: source.beats[0].tonal_class = -1
            case 9: source.beats[0].tonal_class = 24
            case 10: source.keys[0].root = -1
            case 11: source.keys[0].root = 12
            case 12: source.sections[0] = -2
            case 13: source.sections[0] = 100
            case 14: withUnsafeMutableBytes(of: &source.features) {
                $0.storeBytes(of: UInt32(33), toByteOffset: 0x94 - 0x10, as: UInt32.self)
            }
            case 15: withUnsafeMutableBytes(of: &source.features) {
                $0.storeBytes(of: Double.infinity, toByteOffset: 0x2e0 - 0x10, as: Double.self)
            }
            default: break
            }
            withInput(source, item) { input in
                switch variant {
                case 16: input.features = nil
                case 17: input.beats = nil
                case 18: input.keys = nil
                case 19: input.sections = nil
                case 20: input.count = 961
                case 21: input.volume = .nan
                case 22: input.volume = .infinity
                case 23: input.chorus_type = -2
                case 24: input.chorus_type = 100
                case 25: input.chorus_beat = input.count + 1
                default: break
                }
                XCTAssertEqual(negi_sensme_encode_smfmf(&input, nil, 0), 0, "variant \(variant)")
                XCTAssertEqual(negi_sensme_encode_smfmf(&input, &output, output.count), 0, "variant \(variant)")
                XCTAssertEqual(output, [UInt8](repeating: 0xa5, count: 128))
            }
        }
    }
}
