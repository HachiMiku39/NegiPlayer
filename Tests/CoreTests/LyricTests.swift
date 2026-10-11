import XCTest
@testable import LyricCore

final class LyricTests: XCTestCase {
    func testPrecisionAndLongMinutes() throws {
        let d = try LyricFormats.lrc("[100:02.123456789]long\n")
        XCTAssertEqual(d.rows[0].start?.nanoseconds, 6_002_123_456_789)
        XCTAssertEqual(try LyricFormats.exportLRC(d), "[100:02.123456789]long\n")
        XCTAssertThrowsError(try LyricTime.decimal("0.0000000001"))
        XCTAssertThrowsError(try LyricTime.timestamp("00:60.0"))
    }
    func testGraphemesAndUTF16() throws {
        let tokens = LyricFormats.timingUnits("𠮷、😀あ か\u{3099}！", mode: .character)
        XCTAssertEqual(tokens.map(\.text), ["𠮷", "あ", "か\u{3099}"])
        XCTAssertEqual(tokens.map(\.utf16Offset), [0, 5, 7])
        var d = try LyricFormats.plain("𠮷、😀あ", mode: .character)
        d.rows[0].tokens[1].utf16Offset = 3
        XCTAssertThrowsError(try LyricFormats.validate(d))
    }
    func testEnhancedRoundTripPreservesAllText() throws {
        let text = "[00:02.100001]  😀<00:02.100001>か\u{3099}、 <00:03.000009>あ！  \n"
        let d = try LyricFormats.lrc(text)
        XCTAssertEqual(d.rows[0].text, "  😀か\u{3099}、 あ！  ")
        let out = try LyricFormats.exportLRC(d)
        let restored = try LyricFormats.lrc(out)
        XCTAssertEqual(restored.rows.map(\.text), d.rows.map(\.text))
        XCTAssertEqual(restored.rows[0].tokens.map(\.utf16Offset), d.rows[0].tokens.map(\.utf16Offset))
        XCTAssertEqual(restored.rows[0].tokens.map { $0.start?.nanoseconds }, d.rows[0].tokens.map { $0.start?.nanoseconds })
    }
    func testOffsetInverseZeroAndNullPersistence() throws {
        var d = try LyricFormats.plain("hello\nworld")
        d.offset = .init(nanoseconds: 500_000_000)
        try d.stamp(row: 0, token: nil, mediaTime: .init(nanoseconds: 100_000_000))
        XCTAssertEqual(d.rows[0].start?.nanoseconds, -400_000_000)
        XCTAssertNil(d.rows[1].start)
        let bytes = try JSONEncoder().encode(d)
        let restored = try JSONDecoder().decode(LyricDocument.self, from: bytes)
        XCTAssertEqual(restored, d)
        XCTAssertEqual(restored.displayTime(restored.rows[0].start!).nanoseconds, 100_000_000)
        d.rows.removeLast()
        let lrc = try LyricFormats.exportLRC(d)
        XCTAssertFalse(lrc.contains("offset"))
        XCTAssertEqual(try LyricFormats.lrc(lrc).rows[0].start?.nanoseconds, 100_000_000)
        var zero = try LyricFormats.plain("0")
        try zero.stamp(row: 0, token: nil, mediaTime: .init(nanoseconds: 0))
        XCTAssertEqual(try LyricFormats.exportLRC(zero), "[00:00.000]0\n")
    }
    func testPlainWhitespaceWordsAndSimultaneousRows() throws {
        let d = try LyricFormats.plain("  Hello, don't stop!  \n\n", mode: .word)
        XCTAssertEqual(d.rows.count, 3)
        XCTAssertEqual(d.rows[0].text, "  Hello, don't stop!  ")
        XCTAssertEqual(d.rows[0].tokens.map(\.text), ["Hello,", "don't", "stop!"])
        let duet = try LyricFormats.lrc("[00:00.000]A\n[00:00.000]B\n")
        XCTAssertEqual(try LyricFormats.exportLRC(duet), "[00:00.000]A\n[00:00.000]B\n")
    }
    func testSRTEndAndMarkup() throws {
        let d = try LyricFormats.srt("1\n00:10:01,123456 --> 00:10:03,456789\n<i>hello</i>\n第二行\n\n2\n00:10:04,000 --> 00:10:05,000\nbye")
        XCTAssertEqual(d.rows.count, 2)
        XCTAssertEqual(d.rows[0].text, "<i>hello</i>\n第二行")
        XCTAssertEqual(d.rows[0].start?.nanoseconds, 601_123_456_000)
        XCTAssertEqual(d.rows[0].end?.nanoseconds, 603_456_789_000)
        XCTAssertThrowsError(try LyricFormats.srt("1\n00:00:02,000 --> 00:00:01,000\nbad"))
    }
    func testNegiDraftContinuationAndUnrelatedFieldPreservation() throws {
        let json = #"{"editorVersion":1,"meta":{"id":"test","title":"title","artist":"name","levels":[1,2,3,4,5]},"chart":{"notes":[{"kana":"あ","time":2}],"lyrics":[{"text":"applied","time":2}],"bpm":120,"duration":1200},"custom":{"keep":true},"lyricTiming":{"mode":"character","rows":[{"text":"𠮷、😀あ","time":0.123456789,"tokens":[{"text":"𠮷","offset":0,"time":0.123456789},{"text":"あ","offset":5,"time":null}]}]}}"#
        var d = try LyricFormats.parse(json, extension: "json")
        XCTAssertEqual(d.rows[0].start?.nanoseconds, 123_456_789)
        XCTAssertNil(d.rows[0].tokens[1].start)
        XCTAssertFalse(d.warnings.isEmpty)
        try d.stamp(row: 0, token: 1, mediaTime: .init(nanoseconds: 2_234_567_890))
        let result = try JSONDecoder().decode(JSONValue.self, from: LyricFormats.exportNegi(d))
        XCTAssertEqual(result["chart"], d.importedProject?["chart"])
        XCTAssertEqual(result["custom"], d.importedProject?["custom"])
        let reimport = try LyricFormats.importJSON(result)
        XCTAssertEqual(reimport.rows[0].tokens[1].start?.nanoseconds, 2_234_567_890)
        XCTAssertEqual(reimport.rows[0].tokens[1].utf16Offset, 5)
        XCTAssertThrowsError(try LyricFormats.parse("{\"hello\":123}", extension: "json"))
    }
    func testAppliedOnlyNegiCreatesEditableDraft() throws {
        let json = #"{"editorVersion":1,"chart":{"lyrics":[{"time":0,"text":"hello"}],"notes":[],"duration":9000}}"#
        let d = try LyricFormats.parse(json, extension: "json")
        XCTAssertEqual(d.rows[0].start?.nanoseconds, 0)
        XCTAssertEqual(d.rows[0].text, "hello")
    }
}
