import Foundation
import CryptoKit
import Darwin

public struct MusicTransferError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Only mounted Sony volumes advertising Walkman audio storage are offered as targets.
public struct WalkmanVolume: Identifiable, Equatable, Sendable {
    public let root: URL
    public let name: String
    public let model: String
    public let isCard: Bool
    public let extensions: Set<String>
    public let availableBytes: Int64
    private let device: Int32
    public var id: String { root.path + "|" + String(device) }
    public var musicDirectory: URL { root.appendingPathComponent("MUSIC", isDirectory: true) }

    public static func discover() -> [WalkmanVolume] {
        let fm = FileManager.default
        // The directory fallback also works when Disk Arbitration is unavailable.
        let candidates = (fm.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
            + ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
        let unique = Dictionary(grouping: candidates, by: { $0.standardizedFileURL.path }).values.compactMap(\.first)
        return unique.compactMap { try? inspect($0) }.sorted {
            if $0.isCard != $1.isCard { return !$0.isCard }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func inspect(_ root: URL) throws -> WalkmanVolume {
        let fs = try mountedFilesystem(root)
        guard fs.f_flags & UInt32(MNT_RDONLY) == 0 else { throw MusicTransferError("存储卷为只读") }
        let capability = root.appendingPathComponent("default-capability.xml")
        let attributes = try FileManager.default.attributesOfItem(atPath: capability.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 131_072 else { throw MusicTransferError("设备描述文件过大") }
        let parser = XMLParser(data: try Data(contentsOf: capability))
        let delegate = CapabilityParser(); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.values["class"]?.hasPrefix("WALKMAN/") == true,
              delegate.values["vendor"] == "Sony Corporation",
              let storage = delegate.values["type"], ["INTERNAL", "CARD"].contains(storage), !delegate.extensions.isEmpty else {
            throw MusicTransferError("未识别到 Walkman 存储")
        }
        var info = stat()
        guard stat(root.path, &info) == 0 else { throw MusicTransferError("存储卷已断开") }
        return WalkmanVolume(root: root, name: root.lastPathComponent, model: delegate.values["model"] ?? "WALKMAN",
                             isCard: storage == "CARD", extensions: delegate.extensions,
                             availableBytes: Int64(fs.f_bavail) * Int64(fs.f_bsize), device: info.st_dev)
    }

    /// Recheck the actual mount point and device number, never recreate a missing /Volumes path.
    public func validateMounted() throws -> Int64 {
        let fs = try Self.mountedFilesystem(root)
        var info = stat()
        guard stat(root.path, &info) == 0, info.st_dev == device, fs.f_flags & UInt32(MNT_RDONLY) == 0 else {
            throw MusicTransferError("目标存储已断开或变为只读，请重新选择")
        }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    private static func mountedFilesystem(_ root: URL) throws -> statfs {
        var fs = statfs()
        guard statfs(root.path, &fs) == 0 else { throw MusicTransferError("目标存储已断开") }
        let path = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard root.standardizedFileURL.path == path else { throw MusicTransferError("目标已卸载，请重新连接 Walkman") }
        return fs
    }
}

private final class CapabilityParser: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var extensions: Set<String> = []
    private var text = ""
    private var elements: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { text = ""; elements.append(elementName) }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["class", "vendor", "model", "type"].contains(elementName) { values[elementName] = value }
        if elementName == "extension", elements.contains("audio"), !value.isEmpty { extensions.insert(value.lowercased()) }
        elements.removeLast()
        text = ""
    }
}

public struct MusicTransferItem: Identifiable, Sendable {
    public let source: URL
    public let relativePath: String
    public let size: Int64
    public var id: String { source.standardizedFileURL.path }
    public init(source: URL, relativePath: String) throws {
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize else { throw MusicTransferError("无法读取音乐文件：\(source.lastPathComponent)") }
        self.source = source; self.relativePath = relativePath; self.size = Int64(size)
    }
}

public enum TransferCollisionPolicy: String, CaseIterable, Sendable { case skipExisting, keepBoth }
public enum TransferPhase: Sendable { case copying, verifying }
public struct MusicTransferProgress: Sendable {
    public let filename: String
    public let phase: TransferPhase
    public let completedFiles: Int
    public let copiedFiles: Int
    public let skippedFiles: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}
public struct MusicTransferResult: Sendable {
    public var copied = 0
    public var skipped = 0
    public var bytes: Int64 = 0
}

public enum MusicTransfer {
    /// Portable filenames for FAT/exFAT; preserve the selected relative hierarchy.
    public static func safeRelativePath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MusicTransferError("目标相对路径无效")
        }
        return parts.map { raw in
            var component = String(raw).precomposedStringWithCanonicalMapping
            let forbidden = CharacterSet(charactersIn: "<>:\"\\|?*").union(.controlCharacters)
            component = String(component.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined())
            if component.utf16.count > 180 {
                let ext = (component as NSString).pathExtension
                if !ext.isEmpty, ext.utf16.count < 16 {
                    var stem = (component as NSString).deletingPathExtension
                    while stem.utf16.count + ext.utf16.count + 1 > 180 { stem.removeLast() }
                    component = stem + "." + ext
                } else { while component.utf16.count > 180 { component.removeLast() } }
            }
            component = component.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if component.isEmpty { component = "_" }
            let stem = component.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
            if ["CON", "PRN", "AUX", "NUL"].contains(stem) || (1...9).contains(where: { stem == "COM\($0)" || stem == "LPT\($0)" }) { component = "_" + component }
            return component
        }.joined(separator: "/")
    }

    /// Validate the original selection before an optional local metadata staging copy.
    public static func validateSource(_ item: MusicTransferItem, musicDirectory: URL) throws {
        let source = item.source.resolvingSymlinksInPath().standardizedFileURL.path
        let targetRoot = musicDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard source != targetRoot, !source.hasPrefix(targetRoot + "/") else { throw MusicTransferError("所选音乐已在目标 MUSIC 文件夹内，请选择其他来源或存储") }
        let info = try FileManager.default.attributesOfItem(atPath: item.source.path)
        guard info[.type] as? FileAttributeType == .typeRegular, (info[.size] as? NSNumber)?.int64Value == item.size else { throw MusicTransferError("源文件已改变，请重新添加：\(item.source.lastPathComponent)") }
    }

    /// Runs off the main actor. Writes only new files inside the chosen MUSIC directory.
    public static func run(items: [MusicTransferItem], musicDirectory: URL, policy: TransferCollisionPolicy = .skipExisting,
                           verify: Bool = true, validateDestination: @Sendable () throws -> Int64,
                           progress: @Sendable (MusicTransferProgress) async -> Void) async throws -> MusicTransferResult {
        let fm = FileManager.default
        let music = musicDirectory.standardizedFileURL
        guard !items.isEmpty else { throw MusicTransferError("请先选择音乐") }
        let capacity = try validateDestination()
        var prepared: [(MusicTransferItem, String)] = []
        var required: Int64 = 0
        for item in items {
            try Task.checkCancellation()
            let safe = try safeRelativePath(item.relativePath)
            try validateSource(item, musicDirectory: music)
            let exists = fm.fileExists(atPath: music.appendingPathComponent(safe).path)
            if policy != .skipExisting || !exists {
                let (sum, overflow) = required.addingReportingOverflow(item.size + 131_072)
                guard !overflow else { throw MusicTransferError("所选文件过多") }; required = sum
            }
            prepared.append((item, safe))
        }
        guard required <= capacity else { throw MusicTransferError("目标剩余空间不足，请减少曲目或更换存储") }
        let total = items.reduce(Int64(0)) { $0 + $1.size } * (verify ? 2 : 1)
        var completed: Int64 = 0
        var result = MusicTransferResult()
        for (index, entry) in prepared.enumerated() {
            let (item, relative) = entry
            try Task.checkCancellation(); _ = try validateDestination()
            try ensureDirectories(music, below: music.deletingLastPathComponent())
            var destination = music.appendingPathComponent(relative)
            try ensureDirectories(destination.deletingLastPathComponent(), below: music)
            if fm.fileExists(atPath: destination.path) {
                if policy == .skipExisting {
                    result.skipped += 1; completed += item.size * (verify ? 2 : 1)
                    await progress(.init(filename: relative, phase: .copying, completedFiles: index + 1, copiedFiles: result.copied, skippedFiles: result.skipped, completedBytes: completed, totalBytes: total))
                    continue
                }
                destination = try unusedName(destination)
            }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".negi-\(UUID().uuidString).part")
            do {
                _ = try validateDestination()
                let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                let input = try FileHandle(forReadingFrom: item.source)
                defer { try? input.close(); try? output.close() }
                let before = try fm.attributesOfItem(atPath: item.source.path)
                var digest = SHA256(); var written: Int64 = 0
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation(); _ = try validateDestination()
                    try output.write(contentsOf: data); written += Int64(data.count)
                    if verify { digest.update(data: data) }
                    await progress(.init(filename: relative, phase: .copying, completedFiles: index, copiedFiles: result.copied, skippedFiles: result.skipped, completedBytes: completed + written, totalBytes: total))
                }
                try output.synchronize(); try output.close()
                let after = try fm.attributesOfItem(atPath: item.source.path)
                guard written == item.size, (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
                      (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else { throw MusicTransferError("复制时源文件改变：\(item.source.lastPathComponent)") }
                if verify {
                    let check = try FileHandle(forReadingFrom: temporary); defer { try? check.close() }
                    var readBack = SHA256(); var checked: Int64 = 0
                    while let data = try check.read(upToCount: 1_048_576), !data.isEmpty {
                        try Task.checkCancellation(); _ = try validateDestination()
                        readBack.update(data: data); checked += Int64(data.count)
                        await progress(.init(filename: relative, phase: .verifying, completedFiles: index, copiedFiles: result.copied, skippedFiles: result.skipped, completedBytes: completed + written + checked, totalBytes: total))
                    }
                    guard digest.finalize() == readBack.finalize() else { throw MusicTransferError("复制校验失败：\(item.source.lastPathComponent)") }
                }
                try Task.checkCancellation(); _ = try validateDestination()
                try publish(temporary, to: destination)
                result.copied += 1; result.bytes += written; completed += written * (verify ? 2 : 1)
                await progress(.init(filename: relative, phase: .copying, completedFiles: index + 1, copiedFiles: result.copied, skippedFiles: result.skipped, completedBytes: completed, totalBytes: total))
            } catch {
                // If the mount disappeared, do not touch a replacement path on the host disk.
                if (try? validateDestination()) != nil { try? fm.removeItem(at: temporary) }
                throw error
            }
        }
        return result
    }

    private static func publish(_ temporary: URL, to destination: URL) throws {
        if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        // Sony FAT/exFAT volumes may not implement RENAME_EXCL. FileManager's move
        // refuses existing destinations and performs the same-volume rename there.
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func ensureDirectories(_ directory: URL, below root: URL) throws {
        let fm = FileManager.default
        let base = root.standardizedFileURL
        let path = directory.standardizedFileURL.path
        guard path == base.path || path.hasPrefix(base.path + "/") else { throw MusicTransferError("目标路径越界") }
        let suffix = path.dropFirst(base.path.count).split(separator: "/")
        var current = base
        for part in suffix {
            current.appendPathComponent(String(part), isDirectory: true)
            if fm.fileExists(atPath: current.path) || (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil {
                let info = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard info.isSymbolicLink != true, info.isDirectory == true else { throw MusicTransferError("目标目录包含符号链接或同名文件：\(current.lastPathComponent)") }
            } else { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
        }
    }

    private static func unusedName(_ original: URL) throws -> URL {
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        for n in 2...10_000 {
            let candidate = original.deletingLastPathComponent().appendingPathComponent(stem + " (\(n))" + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw MusicTransferError("同名文件过多，请整理目标目录")
    }
}
