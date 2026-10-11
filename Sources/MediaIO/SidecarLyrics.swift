import Foundation
import LyricCore

public struct SidecarLyricsResult: Sendable {
    public let document: LyricDocument
    public let filename: String
}

public enum SidecarLyrics {
    /// Exact filename stem first; unique exact title second. Never choose an unrelated LRC.
    public static func load(for audio: URL, title: String, root: URL) throws -> SidecarLyricsResult? {
        let dir = audio.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey],options:.skipsHiddenFiles)
        let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path
        let files = entries.filter { url in
            let path = url.resolvingSymlinksInPath().path
            return url.pathExtension.lowercased() == "lrc" && path.hasPrefix(boundary+"/") && (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true
        }
        func normalized(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        func matching(_ name: String) -> URL? {
            let found = files.filter { normalized($0.deletingPathExtension().lastPathComponent) == normalized(name) }
            return found.count == 1 ? found[0] : nil
        }
        guard let url = matching(audio.deletingPathExtension().lastPathComponent) ?? matching(title) else { return nil }
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 8_000_000 else { throw LyricError.invalid("对应 LRC 为空或超过 8 MB") }
        let bytes = try Data(contentsOf:url)
        let text: String?
        if bytes.starts(with:[0xff,0xfe]) { text = String(data:bytes,encoding:.utf16LittleEndian) }
        else if bytes.starts(with:[0xfe,0xff]) { text = String(data:bytes,encoding:.utf16BigEndian) }
        else { text = String(data:bytes,encoding:.utf8) }
        guard let text else { throw LyricError.invalid("对应 LRC 不是 UTF-8／UTF-16，请先转换文字编码") }
        var document = try LyricFormats.parse(text.replacingOccurrences(of:"\u{FEFF}",with:""),extension:"lrc")
        document.rows = document.rows.enumerated().sorted { a,b in
            if a.element.start == b.element.start { return a.offset < b.offset }
            return (a.element.start ?? .init(nanoseconds:.max)) < (b.element.start ?? .init(nanoseconds:.max))
        }.map(\.element)
        return .init(document:document,filename:url.lastPathComponent)
    }
}
