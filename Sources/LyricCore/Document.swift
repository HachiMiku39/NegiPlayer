import Foundation

public enum LyricError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

/// Signed nanoseconds; source spelling retained. Unrepresentable precision is rejected, never rounded.
public struct LyricTime: Codable, Equatable, Comparable, Sendable {
    public var nanoseconds: Int64
    public var original: String?
    public init(nanoseconds: Int64, original: String? = nil) { self.nanoseconds = nanoseconds; self.original = original }
    public static func < (l: Self, r: Self) -> Bool { l.nanoseconds < r.nanoseconds }
    public var seconds: Double { Double(nanoseconds) / 1_000_000_000 }
    public static func seconds(_ value: Double) throws -> Self {
        guard value.isFinite, abs(value) < 9_000_000_000 else { throw LyricError.invalid("时间超出可表达范围") }
        return Self(nanoseconds: Int64((value * 1_000_000_000).rounded()))
    }
    public static func decimal(_ s: String) throws -> Self {
        var str = s; let negative = str.hasPrefix("-"); if str.hasPrefix("-") || str.hasPrefix("+") { str.removeFirst() }
        let p = str.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count <= 2, let whole = Int64(p[0]), whole >= 0, whole < 9_000_000_000 else { throw LyricError.invalid("无效时间：\(s)") }
        let fraction = p.count == 2 ? String(p[1]) : ""
        guard fraction.allSatisfy({ $0.isASCII && $0.isNumber }), fraction.count <= 9 else { throw LyricError.invalid("源时间精度超过纳秒；保留原文件，尚未导入") }
        let n = whole * 1_000_000_000 + (Int64(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0)
        return Self(nanoseconds: negative ? -n : n, original: s)
    }
    public static func timestamp(_ value: String, srt: Bool = false) throws -> Self {
        let value = value.replacingOccurrences(of: ",", with: ".")
        let p = value.split(separator: ":").map(String.init)
        guard p.count == 2 || p.count == 3, let minutes = Int64(p[p.count-2]), minutes >= 0,
              let seconds = try? decimal(p.last!), seconds.nanoseconds >= 0, seconds.nanoseconds < 60_000_000_000 else { throw LyricError.invalid("无效时间戳：\(value)") }
        let hours = p.count == 3 ? Int64(p[0]) : 0
        guard let hours, hours >= 0, hours < 1_000_000, minutes < 100_000_000,
              p.count == 2 || minutes < 60 else { throw LyricError.invalid("无效时间戳：\(value)") }
        let total = hours * 3600 + minutes * 60
        guard total < 9_000_000_000 else { throw LyricError.invalid("时间戳超出可表达范围") }
        return Self(nanoseconds: total * 1_000_000_000 + seconds.nanoseconds, original: value)
    }
    public func lrc() throws -> String {
        guard nanoseconds >= 0 else { throw LyricError.invalid("LRC 不支持负的显示时间；请调整 offset 或保留完整工程") }
        let sec = nanoseconds / 1_000_000_000
        var f = String(format: "%09lld", nanoseconds % 1_000_000_000)
        while f.count > 3 && f.last == "0" { f.removeLast() }
        return String(format: "%02lld:%02lld", sec / 60, sec % 60) + "." + f
    }
}

public enum TimingMode: String, Codable, CaseIterable, Sendable { case line, character, word }
public struct LyricToken: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public var utf16Offset: Int
    public var start: LyricTime?
    public var end: LyricTime?
    public init(text: String, utf16Offset: Int, start: LyricTime? = nil, end: LyricTime? = nil) {
        self.text = text; self.utf16Offset = utf16Offset; self.start = start; self.end = end
    }
}
public struct LyricRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public var start: LyricTime?
    public var end: LyricTime?
    public var reading: String = ""
    public var tokens: [LyricToken]
    public init(text: String, start: LyricTime? = nil, end: LyricTime? = nil, tokens: [LyricToken] = []) {
        self.text = text; self.start = start; self.end = end; self.tokens = tokens
    }
}
public struct LyricDocument: Identifiable, Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var mediaID: String?
    public var audioIdentity: String?
    public var mode: TimingMode = .line
    public var offset = LyricTime(nanoseconds: 0)
    public var rows: [LyricRow] = []
    public var revision = 0
    public var source: String = "新建"
    public var importedProject: JSONValue?
    public var warnings: [String] = []
    public init() {}
    public func displayTime(_ base: LyricTime) -> LyricTime { .init(nanoseconds: base.nanoseconds + offset.nanoseconds) }
    public mutating func stamp(row: Int, token: Int?, mediaTime: LyricTime) throws {
        guard rows.indices.contains(row) else { throw LyricError.invalid("请先选择歌词") }
        let base = LyricTime(nanoseconds: mediaTime.nanoseconds - offset.nanoseconds)
        if let token {
            guard rows[row].tokens.indices.contains(token) else { throw LyricError.invalid("无效歌词单元") }
            rows[row].tokens[token].start = base
            if token == 0 { rows[row].start = base }
        } else { rows[row].start = base }
        revision += 1
    }
    public func activeRow(at time: Double) -> UUID? {
        rows.filter { r in
            guard let t = r.start else { return false }
            return displayTime(t).seconds <= time && (r.end == nil || displayTime(r.end!).seconds >= time)
        }.max(by: { $0.start! < $1.start! })?.id
    }
}

/// Decimal JSON numbers avoid a Double conversion during Negi project import/export.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let v) = self { return v[key] }; return nil }
    public var array: [JSONValue]? { if case .array(let x) = self { return x }; return nil }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var decimal: Decimal? { if case .number(let x) = self { return x }; return nil }
    public var time: LyricTime? {
        get throws {
            if case .null = self { return nil }
            guard let decimal else { throw LyricError.invalid("JSON 时间必须是数值或 null") }
            return try LyricTime.decimal(NSDecimalNumber(decimal: decimal).stringValue)
        }
    }
}
