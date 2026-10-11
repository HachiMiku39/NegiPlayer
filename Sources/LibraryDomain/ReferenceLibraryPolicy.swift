import Foundation

/// Imported music roots are read-only references, including their symlink-resolved locations.
public enum ReferenceLibraryPolicy {
    public static func validateExport(_ destination: URL, musicRoots: [URL]) throws {
        let target = canonicalDestination(destination).path
        for root in musicRoots {
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = path.hasSuffix("/") ? path : path + "/"
            if target == path || target.hasPrefix(prefix) {
                throw NSError(domain: "ReferenceLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "音乐文件夹为只读引用。请将歌词或数据库备份保存到音乐目录之外。"])
            }
        }
    }
    private static func canonicalDestination(_ url: URL) -> URL {
        // Foundation does not resolve an existing symlink parent when the leaf is a new file.
        var parent = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            suffix.append(parent.lastPathComponent); parent.deleteLastPathComponent()
        }
        var resolved = parent.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved
    }
}
