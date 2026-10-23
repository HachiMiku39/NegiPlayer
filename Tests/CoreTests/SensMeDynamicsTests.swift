import XCTest
import CryptoKit
import CSensMeCore

final class SensMeDynamicsTests: XCTestCase {
    private func fixture() -> [UInt16] {
        var seed: UInt32 = 0x39CF1234
        var result: [UInt16] = []
        for frame in 0..<1024 {
            for bin in 0..<72 {
                seed = 1664525 &* seed &+ 1013904223
                let value: UInt16
                if frame < 128 { value = 0 }
                else if frame < 256 { value = frame == 128 && bin % 12 == 0 ? 65535 : 0 }
                else if frame < 512 { value = UInt16(seed >> 16) }
                else if frame < 768 { value = UInt16((frame*73 + bin*911) % 65536) }
                else { value = [0, 1, 2, 1024, 65535][(frame + bin) % 5] }
                result.append(value)
            }
        }
        return result
    }

    func testToneAndOnsetBytesAgainstAuditedAccumulator() throws {
        // Actual DLL output for self-generated energy frames, independent of
        // music, reference coefficients, a VM, or any Windows runtime.
        let expectedTones = [
            "73663f043e69a63237f3f0ad9507b202ff955c1990e2ddfe9fb33841469af3f1",
            "f8efa56a12b4fa696bbe1764b6ab8f4cff47705c5aea2be59d0fcab0569b1c1a",
            "3af6402245537837473749c0ff700b2d2aae5cf9d0f220f68ed75f5653b8f4e3"
        ]
        let expectedOnsets = [
            "a69b8aaba4cc553522b04baa8d6b3dc0dff7ea7f23d390bf1c48207c4cd6d915",
            "29caebf85556c45468750bc9c8749455d4b30eb65d5e125823fe4c633b03d63d",
            "109f4fe63b680637fb97fc4d0498d7ac425a543600eb07766f443f3718990ef6"
        ]
        let state = try XCTUnwrap(negi_sensme_dynamics_create())
        defer { negi_sensme_dynamics_destroy(state) }
        var toneBytes = [Data](repeating: Data(), count: 3)
        var onsetBytes = toneBytes
        fixture().withUnsafeBufferPointer { source in
            for block in 0..<8 {
                var tones = [UInt16](repeating: 0, count: 3*64*12)
                var onsets = [Float](repeating: 0, count: 3*128)
                XCTAssertEqual(negi_sensme_dynamics_block(state, source.baseAddress!.advanced(by: block*128*72), &tones, &onsets), 1)
                for group in 0..<3 {
                    Array(tones[group*768..<(group+1)*768]).withUnsafeBytes { toneBytes[group].append(contentsOf: $0) }
                    let skip = block == 0 ? 52 : 0
                    Array(onsets[group*128+skip..<(group+1)*128]).withUnsafeBytes { onsetBytes[group].append(contentsOf: $0) }
                }
            }
        }
        func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        for group in 0..<3 {
            XCTAssertEqual(digest(toneBytes[group]), expectedTones[group])
            XCTAssertEqual(digest(onsetBytes[group]), expectedOnsets[group])
        }
    }

    func testSilenceInvalidInputAndOriginalWindowLimit() throws {
        let state = try XCTUnwrap(negi_sensme_dynamics_create())
        defer { negi_sensme_dynamics_destroy(state) }
        let input = [UInt16](repeating: 0, count: 128*72)
        var tones = [UInt16](repeating: 9, count: 3*64*12)
        var onsets = [Float](repeating: 9, count: 3*128)
        XCTAssertEqual(negi_sensme_dynamics_block(state, nil, &tones, &onsets), 0)
        XCTAssertTrue(tones.allSatisfy { $0 == 9 })
        XCTAssertTrue(onsets.allSatisfy { $0 == 9 })
        input.withUnsafeBufferPointer { source in
            for _ in 0..<297 { XCTAssertEqual(negi_sensme_dynamics_block(state, source.baseAddress, &tones, &onsets), 1) }
            XCTAssertTrue(tones.allSatisfy { $0 == 0 })
            XCTAssertTrue(onsets.allSatisfy { $0 == 0 })
            tones[0] = 9; onsets[0] = 9
            XCTAssertEqual(negi_sensme_dynamics_block(state, source.baseAddress, &tones, &onsets), 0)
            XCTAssertEqual(tones[0], 9); XCTAssertEqual(onsets[0], 9)
        }
    }
}
