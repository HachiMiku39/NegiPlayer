import Foundation
import AppKit
import Combine
import FileOperations
import MusicEnrichment

@MainActor final class WalkmanTransferModel: ObservableObject {
    @Published private(set) var volumes: [WalkmanVolume] = []
    @Published var selectedVolumeID = ""
    @Published private(set) var items: [MusicTransferItem] = []
    @Published var policy = TransferCollisionPolicy.skipExisting
    @Published var verify = true
    @Published var includeEnrichment = true
    var enrichmentProvider: (([MusicTransferItem]) -> [String: TransferEnrichment])?
    @Published private(set) var busy = false
    @Published private(set) var adding = false
    @Published private(set) var discovering = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress: MusicTransferProgress?
    @Published private(set) var status = ""
    @Published var error: String?
    private var task: Task<MusicTransferResult, Error>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryRevision = 0
    private var scopes: [(URL, Bool)] = []
    private var observers: [NSObjectProtocol] = []
    nonisolated static let audioExtensions: Set<String> = ["mp3", "wav", "flac", "m4a", "mp4", "3gp", "wma", "aif", "aiff", "dsf", "dff", "ape", "aac"]
    var selectedVolume: WalkmanVolume? { volumes.first { $0.id == selectedVolumeID } }
    var selectedBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var incompatibleCount: Int {
        guard let volume = selectedVolume else { return 0 }
        return items.filter { !volume.extensions.contains($0.source.pathExtension.lowercased()) }.count
    }

    init() {
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshVolumes() }
            })
        }
    }
    deinit {
        task?.cancel()
        discoveryTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for (url, started) in scopes where started { url.stopAccessingSecurityScopedResource() }
    }
    func refreshVolumes() {
        volumes.removeAll { (try? $0.validateMounted()) == nil }
        guard discoveryTask == nil else { return }
        discovering = true
        discoveryRevision += 1
        let revision = discoveryRevision
        discoveryTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { WalkmanVolume.discover() }.value
            guard !Task.isCancelled, let self, self.discoveryRevision == revision else { return }
            self.volumes = found
            if self.selectedVolumeID.isEmpty { self.selectedVolumeID = found.first?.id ?? "" }
            // Retain an offline selection instead of silently switching to the other storage.
            self.discovering = false; self.discoveryTask = nil
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.discoveryRevision == revision, self.discovering else { return }
            self.discoveryTask?.cancel(); self.discoveryTask = nil; self.discovering = false
            if self.volumes.isEmpty, !self.busy { self.status = "自动识别未完成，可点击「选择存储…」选择存储卷" }
        }
    }
    func chooseStorage() {
        guard !busy else { return }
        discoveryTask?.cancel(); discoveryTask = nil; discoveryRevision += 1; discovering = false
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.prompt = L("选择存储")
        panel.message = L("请选择 Walkman 机身存储或 SD 卡存储卷的根目录。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scopes.append((url, url.startAccessingSecurityScopedResource()))
        Task {
            do {
                let volume = try await Task.detached(priority: .utility) { try WalkmanVolume.inspect(url) }.value
                volumes.removeAll { $0.root.path == volume.root.path }; volumes.append(volume)
                volumes.sort { !$0.isCard && $1.isCard }; selectedVolumeID = volume.id
                status = ""
            } catch { self.error = error.localizedDescription }
        }
    }
    func add(_ newItems: [MusicTransferItem]) {
        guard !busy, !adding else { return }
        let existing = Set(items.map(\.id))
        var added = Set<String>()
        items += newItems.filter { !existing.contains($0.id) && added.insert($0.id).inserted }
        progress = nil; status = ""
    }
    func remove(_ id: String) { guard !busy, !adding else { return }; items.removeAll { $0.id == id }; progress = nil; status = "" }
    func clear() {
        guard !busy, !adding else { return }
        items = []; progress = nil; status = ""
        for (url, started) in scopes where started { url.stopAccessingSecurityScopedResource() }; scopes = []
    }
    func chooseFiles() {
        guard !busy, !adding else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = L("添加音乐")
        panel.message = L("选择音乐文件或文件夹；文件夹会递归添加音频，并保留内部目录结构。")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        for url in urls { scopes.append((url, url.startAccessingSecurityScopedResource())) }
        adding = true; status = "正在添加音乐…"
        Task {
            do {
                let found = try await Task.detached(priority: .utility) { try Self.collectFiles(urls) }.value
                adding = false; add(found)
                if found.isEmpty { status = "未找到可传输的音频文件" }
            } catch { adding = false; status = ""; self.error = error.localizedDescription }
        }
    }
    nonisolated private static func collectFiles(_ urls: [URL]) throws -> [MusicTransferItem] {
        var result: [MusicTransferItem] = []
        for url in urls {
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if info.isDirectory == true {
                var enumerationError: Error?
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw MusicTransferError("无法读取所选文件夹") }
                for case let file as URL in enumerator {
                    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true, Self.audioExtensions.contains(file.pathExtension.lowercased()) else { continue }
                    let relative = url.lastPathComponent + "/" + file.path.dropFirst(url.path.count + 1)
                    result.append(try MusicTransferItem(source: file, relativePath: String(relative)))
                }
                if let enumerationError { throw enumerationError }
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                result.append(try MusicTransferItem(source: url, relativePath: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent))
            }
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
    func start() {
        guard !busy, !adding, !items.isEmpty, let volume = selectedVolume else { return }
        guard incompatibleCount == 0 else { error = "设备未声明支持部分所选格式，请移除对应文件后重试"; return }
        busy = true; cancelling = false; progress = nil; status = "准备传输…"
        let files = items, collision = policy, shouldVerify = verify
        let enrichments = includeEnrichment ? enrichmentProvider?(files) ?? [:] : [:]
        if !enrichments.isEmpty { status = "正在准备带分析标签的副本…" }
        let work = Task.detached(priority: .utility) { [self] in
            let fm = FileManager.default, staging = FileManager.default.temporaryDirectory.appendingPathComponent("NegiEnriched-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staging) }
            // Keep source validation tied to the original file, before staging changes its path.
            for item in files { try MusicTransfer.validateSource(item, musicDirectory: volume.musicDirectory) }
            let prepared = try files.map { item -> MusicTransferItem in
                guard let value = enrichments[item.id] else { return item }
                try Task.checkCancellation()
                let parent = staging.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                let target = parent.appendingPathComponent(item.source.lastPathComponent)
                try TaggedMusicCopy.write(source: item.source, destination: target, enrichment: value)
                return try MusicTransferItem(source: target, relativePath: item.relativePath)
            }
            return try await MusicTransfer.run(items: prepared, musicDirectory: volume.musicDirectory, policy: collision, verify: shouldVerify,
                                        validateDestination: { try volume.validateMounted() }) { value in
                await self.receive(value)
            }
        }
        task = work
        Task {
            do {
                let result = try await work.value
                status = String(format: L("传输完成：%d 首已复制，%d 首同名跳过"), result.copied, result.skipped)
            } catch is CancellationError {
                status = String(format: L("已取消：保留 %d 首已完成的音乐"), progress?.copiedFiles ?? 0)
            } catch {
                status = String(format: L("传输中断：保留 %d 首已完成的音乐"), progress?.copiedFiles ?? 0)
                self.error = error.localizedDescription
            }
            task = nil; busy = false; cancelling = false; refreshVolumes()
        }
    }
    private func receive(_ value: MusicTransferProgress) { progress = value; status = "" }
    func cancel() { guard busy else { return }; cancelling = true; task?.cancel() }
    func revealDestination() {
        guard let volume = selectedVolume, (try? volume.validateMounted()) != nil else { return }
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: volume.musicDirectory.path) ? volume.musicDirectory : volume.root)
    }
}
