import Foundation
import AppKit
import Combine
import LibraryDomain
import LibraryStore
import MediaIO
import AudioCore
import LyricCore
import UniformTypeIdentifiers
import LANHost

@MainActor final class AppModel: ObservableObject {
    @Published var roots: [LibraryRoot] = []
    @Published var files: [MediaFile] = [] { didSet { rebuildBrowseIndex() } }
    @Published var page: String = "albums"
    @Published var search = "" { didSet { rebuildBrowseIndex() } }
    @Published var codecFilter = "" { didSet { rebuildBrowseIndex() } }
    @Published var rateFilter: SourceRateFilter = .all { didSet { rebuildBrowseIndex() } }
    @Published var availabilityFilter: AvailabilityFilter = .all { didSet { rebuildBrowseIndex() } }
    @Published var trackSort: TrackSort = .path { didSet { rebuildBrowseIndex() } }
    @Published var sortAscending = true { didSet { rebuildBrowseIndex() } }
    @Published private(set) var albumGroups: [[MediaFile]] = []
    @Published private(set) var artistNames: [String] = []
    private(set) var artistCounts: [String: Int] = [:]
    private(set) var availableFileCount = 0
    private var browseFiles: [MediaFile] = []
    private var changingBrowse = false
    private(set) var codecChoices: [String] = []
    @Published var scanning = false
    @Published var scanMessage = ""
    @Published var notice = ""
    @Published var error: String?
    @Published var document = LyricDocument()
    @Published var draftStatus = ""
    @Published var lyricReady = false
    @Published var selectedRow = 0
    @Published var selectedToken: Int? = nil
    @Published var lyricText = ""
    @Published var showQueue = false
    @Published var timelineZoom = 1.0
    @Published var selectedAlbum: String?
    @Published var selectedArtist: String?
    @Published var listeningLyrics: LyricDocument?
    @Published var listeningLyricStatus = ""
    @Published var artworkRevision = 0
    let artworkRepository: ArtworkRepository
    let lan: LANController
    let peer = DesktopLANModel()
    private var listeningTask: Task<Void,Never>?
    private var releaseMembers: [String:[MediaFile]] = [:]
    var discImages: [MediaFile] { files.filter(\.isDiscImage).sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending } }
    var musicFileCount: Int { files.reduce(0) { $0+($1.isDiscImage ? 0 : 1) } }
    var displayLyrics: LyricDocument? { listeningLyrics }
    let playback: PlaybackSession
    private var systemMediaControls: SystemMediaControls?
    let database: LibraryDatabase?
    let databaseURL: URL
    private var access: [String: (URL, Bool)] = [:]
    private var scanTask: Task<[MediaFile], Error>?
    private var saveTask: Task<Void, Never>?
    private var draftLoadTask: Task<Void, Never>?
    private var undoStack: [LyricDocument] = []
    private var redoStack: [LyricDocument] = []
    private var dragCheckpoint = false
    private var keyboardMonitor: Any?
    var filtered: [MediaFile] { browseFiles }
    var browseQuery: BrowseQuery {
        var query = BrowseQuery(); query.text = search; query.codec = codecFilter; query.sourceRate = rateFilter
        query.availability = availabilityFilter; query.sort = trackSort; query.ascending = sortAscending; return query
    }
    func resetBrowse() {
        changingBrowse = true
        search = ""; codecFilter = ""; rateFilter = .all; availabilityFilter = .all; trackSort = .path; sortAscending = true
        changingBrowse = false; rebuildBrowseIndex()
    }
    private func rebuildBrowseIndex() {
        guard !changingBrowse else { return }
        let music = files.filter { !$0.isDiscImage }
        releaseMembers = Dictionary(grouping:music,by:\.releaseKey)
        browseFiles = browseQuery.apply(to: music)
        codecChoices = Array(Set(music.map(\.codec))).sorted()
        availableFileCount = music.reduce(0) { $0 + ($1.available ? 1 : 0) }
        albumGroups = Dictionary(grouping: browseFiles, by: \.releaseKey).values.sorted { ($0.first?.albumDisplay ?? "") < ($1.first?.albumDisplay ?? "") }
        artistCounts = [:]
        for file in browseFiles { for artist in Set(file.artists) { artistCounts[artist,default: 0] += 1 } }
        artistNames = artistCounts.keys.sorted()
        let catalog = music.compactMap { media -> CatalogEntry? in
            guard let root = access[media.rootID]?.0 else { return nil }
            return CatalogEntry(media:media,root:root,source:root.appendingPathComponent(media.relativePath))
        }
        Task { await lan.server?.update(catalog) }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var needsAudioReview: Bool {
        if let expected = document.audioIdentity, let actual = playback.current?.audioIdentity { return expected != actual }
        return false
    }
    var selectedTime: LyricTime? {
        guard document.rows.indices.contains(selectedRow) else { return nil }
        if let token = selectedToken, document.rows[selectedRow].tokens.indices.contains(token) { return document.rows[selectedRow].tokens[token].start }
        return document.rows[selectedRow].start
    }
    init() {
        let folder: URL
        if let p = ProcessInfo.processInfo.environment["LMP_DATA_DIR"] ?? NativeVerification.developmentRequest?.dataDirectory { folder = URL(fileURLWithPath: p) }
        else { folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NegiPlayer") }
        databaseURL = folder.appendingPathComponent("Library.sqlite")
        artworkRepository = ArtworkRepository(cacheDirectory:folder.appendingPathComponent("Caches/Artwork"))
        lan = LANController(directory:folder.appendingPathComponent("LAN"),artwork:artworkRepository)
        let settingsStore = PlaybackPreferencesStore(url: folder.appendingPathComponent("PlaybackSettings.json"))
        let settings: PlaybackPreferences
        var canSaveSettings = true
        var settingsError: String?
        do { settings = try settingsStore.load() } catch {
            settings = .init(); canSaveSettings = false; settingsError = "播放设置读取失败，已保留原文件：\(error.localizedDescription)"
        }
        playback = PlaybackSession(preferences: settings)
        do { database = try LibraryDatabase(url: databaseURL) } catch { database = nil; self.error = error.localizedDescription }
        if let settingsError { self.error = settingsError }
        if canSaveSettings {
            playback.onPreferencesChanged = { [weak self] value in
                do { try settingsStore.save(value) } catch { self?.notice = "播放设置保存失败：\(error.localizedDescription)" }
            }
        }
        systemMediaControls = SystemMediaControls(playback: playback)
        playback.onTrackChanged = { [weak self] media in self?.loadDraft(media); self?.loadListeningLyrics(media) }
        playback.onNext = { [weak self] media in self?.play(media, replaceQueue: false) }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.page == "lyrics", !event.isARepeat,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  event.charactersIgnoringModifiers?.lowercased() == "t",
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !(NSApp.keyWindow?.firstResponder is NSTextField) else { return event }
            self.stamp(eventUptime: event.timestamp, advance: true); return nil
        }
        Task { await restore() }
    }
    deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        for (_, entry) in access where entry.1 { entry.0.stopAccessingSecurityScopedResource() }
    }
    func restore() async {
        guard let database else { return }
        do {
            roots = try await database.roots()
            for i in roots.indices {
                var stale = false
                do {
                    let url = try URL(resolvingBookmarkData: roots[i].bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                    let started = url.startAccessingSecurityScopedResource()
                    let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
                    guard started || !sandboxed else { throw NSError(domain: "Access", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要重新授权"]) }
                    access[roots[i].id] = (url, started)
                    if !FileManager.default.fileExists(atPath: url.path) { roots[i].status = "磁盘离线"; try await database.setOffline(rootID: roots[i].id) }
                    else {
                        roots[i].status = "在线"; roots[i].path = url.path
                        // Upgrade older development bookmarks to the read-only import policy too.
                        roots[i].bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    }
                } catch {
                    roots[i].status = "需要重新授权"; try await database.setOffline(rootID: roots[i].id)
                }
                try await database.save(root: roots[i])
            }
            files = try await database.files()
        } catch { self.error = error.localizedDescription }
    }
    func importFolder(reauthorizing rootID: String? = nil) {
        guard !scanning, let database else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = L(rootID == nil ? "引用音乐文件夹" : "重新授权")
        panel.message = L("只读引用：音乐保留原位，不复制、不改写。索引与歌词草稿保存在本机。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let id = rootID ?? roots.first(where: { $0.path == url.path })?.id ?? UUID().uuidString
            if let entry = access[id], entry.1 { entry.0.stopAccessingSecurityScopedResource() }
            let started = url.startAccessingSecurityScopedResource()
            access[id] = (url, started)
            let root = LibraryRoot(id: id, path: url.path, bookmark: bookmark)
            Task {
                do {
                    try await database.save(root: root); roots = try await database.roots()
                    await scan(root, at: url)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func rescan() {
        guard !scanning else { return }
        Task {
            for root in roots {
                if let url = access[root.id]?.0 { await scan(root, at: url) }
            }
        }
    }
    private func scan(_ root: LibraryRoot, at url: URL) async {
        guard let database else { return }
        scanning = true; scanMessage = "正在扫描 \(url.lastPathComponent)"; defer { scanning = false; scanTask = nil }
        do {
            let previous = try await database.files(rootID: root.id)
            let task = Task.detached(priority: .utility) { [self] in
                try await LibraryScanner.scan(root: root, url: url, previous: previous) { n, path in
                    await reportScanProgress(n, path)
                }
            }
            scanTask = task
            let result = try await task.value
            try await database.commitScan(rootID: root.id, files: result)
            files = try await database.files(); artworkRevision += 1
            notice = "已扫描 \(result.filter { !$0.isDiscImage }.count) 个音乐文件、\(result.filter(\.isDiscImage).count) 个镜像"
            var updated = root; updated.status = "在线"; try await database.save(root: updated); roots = try await database.roots()
        } catch is CancellationError { notice = "扫描已取消，已有曲库保留" }
        catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? await database.setOffline(rootID: root.id)
                var offline = root; offline.status = "磁盘离线"; try? await database.save(root: offline)
                files = (try? await database.files()) ?? files; roots = (try? await database.roots()) ?? roots
            }
            self.error = error.localizedDescription
        }
    }
    func cancelScan() { scanTask?.cancel() }
    private func reportScanProgress(_ n: Int, _ path: String) { scanMessage = "已读取 \(n) 个文件 · \(path)" }
    func url(for media: MediaFile) throws -> URL {
        guard let root = access[media.rootID]?.0 else { throw NSError(domain: "Access", code: 2, userInfo: [NSLocalizedDescriptionKey: "请重新授权曲目所在目录"]) }
        return root.appendingPathComponent(media.relativePath)
    }
    func artworkKey(for media: MediaFile) -> String {
        let group = releaseMembers[media.releaseKey] ?? [media]
        return media.id+"|\(artworkRevision)|"+(access[media.rootID]?.0.path ?? "")+group.map { $0.id+"|\($0.modified)" }.joined(separator:"|")
    }
    func artwork(for media: MediaFile) async -> ArtworkResult? {
        guard let root = access[media.rootID]?.0 else { return nil }
        let group = releaseMembers[media.releaseKey] ?? [media]
        let members = [media]+group.filter { $0.id != media.id && $0.rootID == media.rootID }
        let urls = members.compactMap { try? url(for:$0) }
        return await artworkRepository.artwork(sources:urls,root:root)
    }
    func refreshListeningAssets() {
        Task {
            await artworkRepository.invalidate(musicRoots:access.values.map(\.0))
            artworkRevision += 1
            if let media = playback.current { loadListeningLyrics(media) }
        }
    }
    private func loadListeningLyrics(_ media: MediaFile) {
        listeningTask?.cancel(); listeningLyrics = nil; listeningLyricStatus = "正在查找对应 LRC…"
        guard let source = try? url(for:media), let root = access[media.rootID]?.0 else { listeningLyricStatus = "音乐目录未授权"; return }
        listeningTask = Task {
            do {
                let work = Task.detached(priority:.utility) { try SidecarLyrics.load(for:source,title:media.title,root:root) }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation(); guard playback.current?.id == media.id else { return }
                listeningLyrics = result?.document
                listeningLyricStatus = result.map { "对应 LRC · "+$0.filename } ?? "未找到对应 LRC"
            } catch is CancellationError { }
            catch { if playback.current?.id == media.id { listeningLyricStatus = "LRC 未载入：\(error.localizedDescription)" } }
        }
    }
    func play(_ media: MediaFile, replaceQueue: Bool = true) {
        peer.player.pause()
        Task {
            do {
                let url = try url(for: media)
                if replaceQueue { try await playback.setQueue(filtered, startingAt: media, url: url) }
                else { try await playback.load(media, url: url, autoplay: true) }
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    func toggle() { peer.player.pause(); do { try playback.toggle() } catch { self.error = error.localizedDescription } }
    func enqueue(_ media: MediaFile, next: Bool) {
        if !next, playback.queue.contains(where: { $0.id == media.id }) {
            showQueue = true; notice = "队列中已有：\(media.title)"; return
        }
        playback.enqueue(media, next: next); showQueue = true
        notice = next ? "已安排下一首：\(media.title)" : "已加入队列：\(media.title)"
    }
    func seek(_ seconds: Double) { do { try playback.seek(to: seconds) } catch { self.error = error.localizedDescription } }
    func reveal(_ media: MediaFile) { do { NSWorkspace.shared.activateFileViewerSelecting([try url(for: media)]) } catch { self.error = error.localizedDescription } }
    private func loadDraft(_ media: MediaFile) {
        draftLoadTask?.cancel()
        lyricReady = false; document = LyricDocument(); document.mediaID = media.id
        undoStack = []; redoStack = []; lyricText = ""; draftStatus = "正在校验当前音频版本…"
        draftLoadTask = Task {
            await saveTask?.value
            do {
                let source = try url(for: media)
                let identityTask = Task.detached(priority: .utility) { () throws -> String in
                    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
                    let before = try source.resourceValues(forKeys: keys)
                    guard Int64(before.fileSize ?? 0) == media.size, before.contentModificationDate?.timeIntervalSince1970 == media.modified else {
                        throw NSError(domain: "Binding", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频文件在扫描后改变，请重新扫描"])
                    }
                    let identity = try AudioIdentity.digest(source)
                    let after = try source.resourceValues(forKeys: keys)
                    guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                        throw NSError(domain: "Binding", code: 2, userInfo: [NSLocalizedDescriptionKey: "校验期间音频文件改变，请重试"])
                    }
                    return identity
                }
                let identity = try await withTaskCancellationHandler { try await identityTask.value } onCancel: { identityTask.cancel() }
                try Task.checkCancellation()
                guard playback.current?.id == media.id else { return }
                try await database?.saveAudioIdentity(identity, for: media)
                playback.updateAudioIdentity(mediaID: media.id, identity: identity)
                if let i = files.firstIndex(where: { $0.id == media.id }) { files[i].audioIdentity = identity }
                let draft = try await database?.draft(mediaID: media.id)
                try Task.checkCancellation()
                guard playback.current?.id == media.id else { return }
                document = draft ?? LyricDocument(); document.mediaID = media.id
                if draft == nil { document.audioIdentity = identity }
                else if needsAudioReview { document.warnings.append("音频载荷已改变；请核对母带、长度和前导静音后，确认重新关联。") }
                selectedRow = 0; selectedToken = document.mode == .line ? nil : 0
                lyricText = document.rows.map(\.text).joined(separator: "\n")
                undoStack = []; redoStack = []; draftStatus = draft == nil ? "尚无歌词草稿" : "已恢复歌词草稿"
                lyricReady = true
            } catch is CancellationError { }
            catch { if playback.current?.id == media.id { draftStatus = "歌词版本校验未完成：\(error.localizedDescription)" } }
        }
    }
    func changeMode(_ mode: TimingMode) {
        edit { d in
            d.mode = mode
            if mode != .line {
                for i in d.rows.indices where d.rows[i].tokens.allSatisfy({ $0.start == nil }) { d.rows[i].tokens = LyricFormats.timingUnits(d.rows[i].text, mode: mode) }
            }
        }
        selectedToken = mode == .line ? nil : 0
    }
    func prepareLyrics() {
        guard playback.current != nil else { error = "请先载入曲目，歌词将绑定到该音频文件版本"; return }
        do {
            var d = try LyricFormats.plain(lyricText, mode: document.mode); d.mediaID = playback.current?.id; d.audioIdentity = playback.current?.audioIdentity
            edit { $0 = d }; selectedRow = 0; selectedToken = d.mode == .line ? nil : 0
        } catch { self.error = error.localizedDescription }
    }
    func importLyrics() {
        guard let current = playback.current else { error = "请先载入曲目"; return }
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType.plainText, .json, UTType(filenameExtension: "lrc") ?? .plainText, UTType(filenameExtension: "srt") ?? .plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let resource = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (resource.fileSize ?? 0) <= 8_000_000 else { throw LyricError.invalid("歌词超过 8 MB") }
            var d = try LyricFormats.parse(String(contentsOf: url, encoding: .utf8), extension: url.pathExtension.lowercased())
            if d.mediaID != nil && d.mediaID != current.id { d.warnings.append("导入工程原来绑定其他音频版本；请核对母带、长度和前导静音。") }
            d.mediaID = current.id
            if d.audioIdentity == nil { d.audioIdentity = current.audioIdentity }
            edit { $0 = d }; selectedRow = 0; selectedToken = d.mode == .line ? nil : 0
            lyricText = d.rows.map(\.text).joined(separator: "\n"); page = "lyrics"
        } catch { self.error = error.localizedDescription }
    }
    func exportLyrics(kind: String) {
        do {
            let data: Data
            if kind == "lrc" {
                data = Data(try LyricFormats.exportLRC(document).utf8)
                notice = "LRC 已合并 offset；不包含编辑历史、未打点数据和显式结束时间。完整工程保留这些字段。"
            } else if kind == "negi" { data = try LyricFormats.exportNegi(document) }
            else if kind == "txt" { data = Data(document.rows.map(\.text).joined(separator: "\n").utf8) }
            else { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try e.encode(document) }
            let p = NSSavePanel(); p.nameFieldStringValue = "\(playback.current?.title ?? "歌词").\(kind == "negi" ? "negi-project.json" : kind == "project" ? "lyrics-project.json" : kind)"
            guard p.runModal() == .OK, let url = p.url else { return }
            let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
            try ReferenceLibraryPolicy.validateExport(url, musicRoots: roots.map { access[$0.id]?.0 ?? URL(fileURLWithPath: $0.path) })
            try data.write(to: url, options: .atomic); notice = "已导出 \(url.lastPathComponent)" + (kind == "lrc" ? "；LRC 不包含结束时间和编辑历史" : "")
        } catch { self.error = error.localizedDescription }
    }
    func edit(checkpoint: Bool = true, _ operation: (inout LyricDocument) throws -> Void) {
        guard lyricReady else { error = "请等待音频版本校验完成后编辑歌词"; return }
        do {
            var next = document; try operation(&next); try LyricFormats.validate(next)
            if checkpoint { undoStack.append(document); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack = [] }
            next.revision = document.revision + 1; document = next; persistDraft()
        } catch { self.error = error.localizedDescription }
    }
    func persistDraft() {
        guard let id = document.mediaID, let database else { return }
        let snapshot = document; let preceding = saveTask; draftStatus = "保存草稿…"
        saveTask = Task {
            await preceding?.value
            do { try await database.saveDraft(snapshot, mediaID: id); if document.id == snapshot.id && document.revision == snapshot.revision { draftStatus = "草稿已保存到音乐库" } }
            catch { self.error = error.localizedDescription; draftStatus = "草稿保存失败，修改仍在编辑器中" }
        }
    }
    func stamp(eventUptime: Double, advance: Bool) {
        guard lyricReady else { return }
        guard !needsAudioReview else { error = "音频载荷与歌词原绑定不同，请核对后确认重新关联"; return }
        guard document.rows.indices.contains(selectedRow) else { return }
        do {
            let time = try LyricTime.seconds(playback.mediaTime(forEventUptime: eventUptime))
            let r = selectedRow; let t = document.mode == .line ? nil : selectedToken
            edit(checkpoint: !dragCheckpoint) { try $0.stamp(row: r, token: t, mediaTime: time) }
            if advance { nextUntimed() }
        } catch { self.error = error.localizedDescription }
    }
    func nextUntimed() {
        for r in document.rows.indices {
            if document.mode == .line { if document.rows[r].start == nil { selectedRow = r; selectedToken = nil; return } }
            else if let t = document.rows[r].tokens.firstIndex(where: { $0.start == nil }) { selectedRow = r; selectedToken = t; return }
        }
        notice = "当前歌词已全部打点"
    }
    func confirmAudioBinding() { edit { $0.audioIdentity = playback.current?.audioIdentity; $0.warnings.removeAll { $0.contains("音频载荷已改变") } } }
    func select(_ row: Int, _ token: Int? = nil) { selectedRow = row; selectedToken = token }
    func adjustSelected(_ ms: Int64) {
        guard let t = selectedTime else { return }
        setSelectedBase(.init(nanoseconds: t.nanoseconds + ms*1_000_000))
    }
    func setSelectedBase(_ time: LyricTime?) {
        guard document.rows.indices.contains(selectedRow) else { return }
        let r = selectedRow; let t = selectedToken
        edit { d in
            if let t, d.rows[r].tokens.indices.contains(t) { d.rows[r].tokens[t].start = time; if t == 0 { d.rows[r].start = time } }
            else { d.rows[r].start = time }
        }
    }
    func beginDrag() { if !dragCheckpoint { undoStack.append(document); redoStack = []; dragCheckpoint = true } }
    func endDrag() { dragCheckpoint = false }
    func dragStamp(row: Int, token: Int?, eventUptime: Double) { beginDrag(); select(row, token); stamp(eventUptime: eventUptime, advance: false) }
    func undo() { guard let d = undoStack.popLast() else { return }; redoStack.append(document); let revision = document.revision+1; document = d; document.revision = revision; persistDraft() }
    func redo() { guard let d = redoStack.popLast() else { return }; undoStack.append(document); let revision = document.revision+1; document = d; document.revision = revision; persistDraft() }
    func checkDatabase() {
        Task { do { notice = "数据库完整性：" + (try await database?.integrityCheck() ?? "不可用") } catch { self.error = error.localizedDescription } }
    }
    func backupDatabase() {
        let p = NSSavePanel(); p.nameFieldStringValue = "NegiPlayer-backup-\(Int(Date().timeIntervalSince1970)).sqlite"
        guard p.runModal() == .OK, let destination = p.url else { return }
        let scope = destination.startAccessingSecurityScopedResource()
        Task {
            defer { if scope { destination.stopAccessingSecurityScopedResource() } }
            do {
                try ReferenceLibraryPolicy.validateExport(destination, musicRoots: roots.map { access[$0.id]?.0 ?? URL(fileURLWithPath: $0.path) })
                try await database?.backup(to: destination); notice = "一致数据库备份已保存；不包含音乐文件"
            }
            catch { self.error = error.localizedDescription }
        }
    }
}
