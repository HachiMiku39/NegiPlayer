import Foundation

// Independent Swift implementation of NegiFlick-compatible timing semantics, cf64f049… . See THIRD_PARTY.md.
public enum LyricFormats {
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func part(_ text: String, _ m: NSTextCheckingResult, _ group: Int) -> String {
        let ns = text as NSString; return ns.substring(with: m.range(at: group))
    }
    public static func timingUnits(_ text: String, mode: TimingMode) -> [LyricToken] {
        if mode == .word {
            return matches(#"\S+"#, text).map { .init(text: (text as NSString).substring(with: $0.range), utf16Offset: $0.range.location) }
        }
        var offset = 0; var result: [LyricToken] = []
        for c in text {
            let s = String(c)
            if s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || "ー〜".unicodeScalars.contains($0) }) {
                result.append(.init(text: s, utf16Offset: offset))
            }
            offset += s.utf16.count
        }
        return result
    }
    public static func plain(_ text: String, mode: TimingMode = .line) throws -> LyricDocument {
        let text = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !text.isEmpty, text.utf8.count <= 8_000_000 else { throw LyricError.invalid("歌词为空或超过 8 MB") }
        var d = LyricDocument(); d.mode = mode; d.source = "TXT"
        d.rows = text.components(separatedBy: "\n").map { .init(text: $0, tokens: timingUnits($0, mode: mode)) }
        try validate(d); return d
    }
    public static func parse(_ text: String, extension ext: String) throws -> LyricDocument {
        guard text.utf8.count <= 8_000_000 else { throw LyricError.invalid("歌词超过 8 MB") }
        if ext == "txt" { return try plain(text) }
        if ext == "json" {
            let data = Data(text.utf8)
            let j = try JSONDecoder().decode(JSONValue.self, from: data)
            if j["schemaVersion"] != nil && j["rows"] != nil {
                let d = try JSONDecoder().decode(LyricDocument.self, from: data)
                guard d.schemaVersion == 1 else { throw LyricError.invalid("不支持的播放器歌词工程版本") }
                try validate(d); return d
            }
            return try importJSON(j)
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if ext == "srt" { return try srt(normalized) }
        return try lrc(normalized)
    }
    public static func lrc(_ text: String) throws -> LyricDocument {
        var d = LyricDocument(); d.source = "LRC"
        if let m = matches(#"(?i)\[offset:([+-]?\d+)\]"#, text).first {
            guard let ms = Int64(part(text, m, 1)), ms > -9_000_000_000_000, ms < 9_000_000_000_000 else { throw LyricError.invalid("offset 超出范围") }
            d.offset = .init(nanoseconds: ms * 1_000_000)
        }
        for line in text.components(separatedBy: "\n") {
            let tags = matches(#"\[(\d+:\d{2}(?:[.,]\d+)?)\]"#, line)
            guard !tags.isEmpty else { continue }
            // Only strip leading line timestamps; brackets in the actual lyric are preserved.
            var cursor = 0
            for m in tags { guard m.range.location == cursor else { break }; cursor = NSMaxRange(m.range) }
            let relevant = tags.filter { NSMaxRange($0.range) <= cursor }
            guard !relevant.isEmpty else { continue }
            let body = (line as NSString).substring(from: cursor)
            var clean = ""; var tokens: [LyricToken] = []; var bodyCursor = 0
            let tokenTags = matches(#"<(\d+:\d{2}(?:[.,]\d+)?)>"#, body)
            for (i, m) in tokenTags.enumerated() {
                if m.range.location > bodyCursor { clean += (body as NSString).substring(with: NSRange(location: bodyCursor, length: m.range.location-bodyCursor)) }
                let stop = i+1 < tokenTags.count ? tokenTags[i+1].range.location : (body as NSString).length
                let segment = (body as NSString).substring(with: NSRange(location: NSMaxRange(m.range), length: stop-NSMaxRange(m.range)))
                tokens.append(.init(text: segment, utf16Offset: clean.utf16.count, start: try .timestamp(part(body, m, 1))))
                clean += segment; bodyCursor = stop
            }
            if tokenTags.isEmpty { clean = body }
            else if bodyCursor < (body as NSString).length { clean += (body as NSString).substring(from: bodyCursor) }
            for tag in relevant { d.rows.append(.init(text: clean, start: try .timestamp(part(line, tag, 1)), tokens: tokens)) }
            if !tokens.isEmpty { d.mode = .character }
        }
        guard !d.rows.isEmpty else { throw LyricError.invalid("没有发现 LRC 时间戳；纯文本请以 TXT 导入") }
        try validate(d); return d
    }
    public static func srt(_ text: String) throws -> LyricDocument {
        var d = LyricDocument(); d.source = "SRT"
        let re = try NSRegularExpression(pattern: #"\n[\t ]*\n"#)
        let split = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\u{001F}")
        for block in split.components(separatedBy: "\u{001F}") {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[i].components(separatedBy: "-->")
            guard timing.count == 2 else { throw LyricError.invalid("SRT 时间行无效") }
            let a = timing[0].trimmingCharacters(in: .whitespaces)
            let b = timing[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]
            let body = lines.dropFirst(i+1).joined(separator: "\n")
            d.rows.append(.init(text: body, start: try .timestamp(a, srt: true), end: try .timestamp(b, srt: true)))
        }
        guard !d.rows.isEmpty else { throw LyricError.invalid("没有发现 SRT 字幕") }
        d.warnings = ["SRT 的文本标记保留为原文；LRC 导出不携带显式结束时间。"]
        try validate(d); return d
    }
    public static func importJSON(_ j: JSONValue) throws -> LyricDocument {
        var d = LyricDocument(); d.source = "lyrics JSON"
        let negi = j["editorVersion"] != nil
        if negi {
            guard j["editorVersion"]?.decimal == 1, j["chart"] != nil else { throw LyricError.invalid("不支持的 Negi 工程版本") }
            d.importedProject = j; d.source = "NegiFlick editorVersion 1"
        }
        let draft = j["lyricTiming"]
        let chartRows = j["chart"]?["lyrics"]?.array
        let rows = draft?["rows"]?.array ?? chartRows ?? j["lyrics"]?.array ?? j.array
        guard let rows else { throw LyricError.invalid("JSON 必须含明确的 lyrics 数组或 Negi 工程结构") }
        if let s = draft?["mode"]?.string, let mode = TimingMode(rawValue: s) { d.mode = mode }
        for r in rows {
            guard let text = r["text"]?.string else { throw LyricError.invalid("歌词行缺少 text") }
            var row = LyricRow(text: text, start: try r["time"]?.time, end: try r["end"]?.time)
            row.reading = r["reading"]?.string ?? ""
            if let tokens = r["tokens"]?.array {
                for t in tokens {
                    guard let s = t["text"]?.string, let o = t["offset"]?.decimal, o >= 0,
                          o < 8_000_000, o == Decimal(NSDecimalNumber(decimal: o).intValue) else { throw LyricError.invalid("歌词 token 缺少有效 UTF-16 offset") }
                    row.tokens.append(.init(text: s, utf16Offset: NSDecimalNumber(decimal: o).intValue, start: try t["time"]?.time, end: try t["end"]?.time))
                }
                if draft == nil && !row.tokens.isEmpty { d.mode = .character }
            } else { row.tokens = timingUnits(text, mode: d.mode) }
            d.rows.append(row)
        }
        if draft != nil, let chartRows {
            // Preserve chart regardless; expose potentially distinct applied lyrics instead of silently replacing them.
            if chartRows != draft?["rows"]?.array { d.warnings.append("使用 lyricTiming 草稿续编；chart.lyrics 原样保留，可能与草稿不同。回导不会自动应用到游戏谱面。") }
        }
        try validate(d); return d
    }
    public static func validate(_ d: LyricDocument) throws {
        guard d.rows.count <= 50_000, d.rows.reduce(0, { $0+$1.tokens.count }) <= 200_000 else { throw LyricError.invalid("歌词超过 50,000 行或 200,000 单元；请拆分后导入") }
        guard d.offset.nanoseconds > -1_000_000_000_000_000, d.offset.nanoseconds < 1_000_000_000_000_000 else { throw LyricError.invalid("offset 超出范围") }
        for r in d.rows {
            let times = [r.start, r.end] + r.tokens.flatMap { [$0.start, $0.end] }
            guard times.compactMap({ $0 }).allSatisfy({ $0.nanoseconds > -8_000_000_000_000_000_000 && $0.nanoseconds < 8_000_000_000_000_000_000 }) else { throw LyricError.invalid("时间超出可表达范围") }
            if let a = r.start, let b = r.end, b < a { throw LyricError.invalid("结束时间早于开始时间") }
            let ns = r.text as NSString; var stop = 0
            var graphemeBoundaries: Set<Int> = [ns.length]
            var boundary = 0
            for character in r.text { graphemeBoundaries.insert(boundary); boundary += String(character).utf16.count }
            for t in r.tokens {
                let len = t.text.utf16.count
                guard t.utf16Offset >= stop, t.utf16Offset <= ns.length, len <= ns.length-t.utf16Offset,
                      ns.substring(with: .init(location: t.utf16Offset, length: len)) == t.text,
                      graphemeBoundaries.contains(t.utf16Offset), graphemeBoundaries.contains(t.utf16Offset+len) else { throw LyricError.invalid("UTF-16 token 范围与原文字素簇不一致") }
                if let a = t.start, let b = t.end, b < a { throw LyricError.invalid("单元结束时间早于开始时间") }
                stop = t.utf16Offset + len
            }
        }
    }
    public static func exportLRC(_ d: LyricDocument) throws -> String {
        try validate(d)
        return try d.rows.map { r in
            guard let start = r.start else { throw LyricError.invalid("仍有未打点行，请保留完整工程或完成打点") }
            var body = r.text
            if d.mode != .line && !r.tokens.isEmpty {
                let ns = r.text as NSString; body = ""; var cursor = 0
                for t in r.tokens {
                    guard let time = t.start else { throw LyricError.invalid("仍有未打点单元") }
                    body += ns.substring(with: NSRange(location: cursor, length: t.utf16Offset-cursor))
                    body += "<" + (try d.displayTime(time).lrc()) + ">" + t.text
                    cursor = t.utf16Offset+t.text.utf16.count
                }
                body += ns.substring(from: cursor)
            }
            return "[" + (try d.displayTime(start).lrc()) + "]" + body
        }.joined(separator: "\n") + "\n"
    }
    public static func exportNegi(_ d: LyricDocument) throws -> Data {
        guard case .object(var p) = d.importedProject else { throw LyricError.invalid("只有从 Negi 工程导入的文档可以回导；新文档请保存播放器工程") }
        guard !d.rows.contains(where: { $0.end != nil || $0.tokens.contains(where: { $0.end != nil }) }) else { throw LyricError.invalid("Negi 草稿不表达显式结束时间；请保存播放器工程") }
        func time(_ t: LyricTime?) -> JSONValue {
            guard let t else { return .null }
            return .number(Decimal(d.displayTime(t).nanoseconds) / 1_000_000_000)
        }
        p["lyricTiming"] = .object(["mode": .string(d.mode.rawValue), "rows": .array(d.rows.map { r in
            .object(["text": .string(r.text), "time": time(r.start), "reading": .string(r.reading),
                     "tokens": .array(r.tokens.map { .object(["text": .string($0.text), "offset": .number(Decimal($0.utf16Offset)), "time": time($0.start)]) })])
        })])
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(JSONValue.object(p))
    }
}
