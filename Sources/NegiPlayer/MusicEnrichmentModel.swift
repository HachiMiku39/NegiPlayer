import Foundation
import AppKit
import Combine
import CryptoKit
import LibraryDomain
import MusicEnrichment
import FileOperations

struct EnrichedTrack: Codable, Sendable {
    var mediaID: String
    var sourcePath: String
    var sourceSHA256: String
    var sensme: CachedSensMe?
    var sensmeHistory: [CachedSensMe]?
    var candidates: [GracenoteCandidate] = []
    var approvedMetadata: MetadataPatch?
    var approvedArtwork: String?
}

struct SensMeTrackFailure: Codable, Sendable {
    let mediaID: String
    let sourcePath: String
    let message: String
    let failedAt: Date
}

@MainActor final class MusicEnrichmentModel: ObservableObject {
    @Published private(set) var records: [String: EnrichedTrack] = [:]
    @Published private(set) var analysisFailures: [String: SensMeTrackFailure] = [:]
    @Published private(set) var engineDirectory: URL
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published var error: String?
    @Published var selectedIDs = Set<String>()
    @Published var focusedID: String?
    @Published var queryTitle = ""
    @Published var queryArtist = ""
    @Published var queryAlbum = ""
    @Published private(set) var candidates: [GracenoteCandidate] = []
    @Published private(set) var candidateMediaID: String?
    @Published private(set) var credentialsReady = false
    @Published private(set) var selectedCandidateID: String?
    @Published var selectedFields = Set<MetadataField>()
    @Published var selectedCoverID: String?
    @Published var useSelectedCover = false
    @Published private(set) var coverPreview: EnrichmentArtwork?
    @Published private(set) var previewAssetID: String?
    private var coverTask: Task<EnrichmentArtwork, Error>?
    var selectedCandidate: GracenoteCandidate? { candidates.first { $0.id == selectedCandidateID } }
    let directory: URL
    private var scopes: [(URL, Bool)] = []
    private var analysisTask: Task<Void, Error>?
    private var analysisSummary = SensMeBatchSummary()
    private var queryTask: Task<(GracenoteResponse, String), Error>?
    var runtime: EnrichmentRuntime {
        .init(directory: engineDirectory, prefix: directory.appendingPathComponent("WinePrefix"), helpers: Bundle.main.resourceURL!.appendingPathComponent("Enrichment"))
    }
    var sensmeReady: Bool { SensMeEngine.isAvailable }
    var gracenoteReady: Bool { runtime.gracenoteReady }
    var credentials: URL { directory.appendingPathComponent("Gracenote/credentials.json") }
    init(directory: URL) {
        self.directory = directory
        let saved = UserDefaults.standard.string(forKey: "music-engine-directory")
        engineDirectory = saved.map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("NegiPlayer-Engines")
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Records"), withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Records"), includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                if let value = try? JSONDecoder().decode(EnrichedTrack.self, from: Data(contentsOf: file)) { records[value.mediaID] = value }
            }
            let failures = directory.appendingPathComponent("SensMeFailures")
            try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: failures, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                if let value = try? JSONDecoder().decode(SensMeTrackFailure.self, from: Data(contentsOf: file)) { analysisFailures[value.mediaID] = value }
            }
        } catch { self.error = error.localizedDescription }
        credentialsReady = FileManager.default.fileExists(atPath: credentials.path)
        importBundledMediaGoIfPresent()
    }
    deinit {
        analysisTask?.cancel(); queryTask?.cancel(); coverTask?.cancel()
        for (url, started) in scopes where started { url.stopAccessingSecurityScopedResource() }
    }
    func select(_ media: MediaFile) {
        guard !busy else { return }
        focusedID = media.id; queryTitle = media.title; queryArtist = media.artists.joined(separator: "; "); queryAlbum = media.album
        candidates = records[media.id]?.candidates ?? []; candidateMediaID = media.id; resetDraft()
    }
    func chooseRuntime() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = L("选择引擎文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scopes.append((url, url.startAccessingSecurityScopedResource())); engineDirectory = url
        UserDefaults.standard.set(url.path, forKey: "music-engine-directory"); importBundledMediaGoIfPresent()
    }
    private func importBundledMediaGoIfPresent() {
        let source = engineDirectory.appendingPathComponent("Gracenote/MediaGo.exe")
        if !credentialsReady, FileManager.default.fileExists(atPath: source.path) { importCredentials(source) }
    }
    func chooseMediaGo() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = L("选择已核对的 Media Go 3.2 Build 191 的 MediaGo.exe。授权只保存在本机。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scopes.append((url, url.startAccessingSecurityScopedResource())); importCredentials(url)
    }
    private func importCredentials(_ source: URL) {
        let target = credentials
        Task {
            do {
                try await Task.detached(priority: .utility) { try MediaGoCredentials.importExecutable(source, to: target) }.value
                credentialsReady = true
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save(_ record: EnrichedTrack) throws {
        let key = SHA256.hash(data: Data(record.mediaID.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("Records/" + key + ".json"), options: .atomic)
        records[record.mediaID] = record
    }
    func analyze(_ inputs: [(MediaFile, URL)]) {
        guard !busy, !inputs.isEmpty else { return }
        busy = true; status = "正在准备 SensMe 分析…"
        analysisSummary = SensMeBatchSummary()
        let media = Dictionary(inputs.map { ($0.0.id, $0.0) }, uniquingKeysWith: { first, _ in first })
        let jobs = inputs.map { input in
            let record = records[input.0.id]
            return SensMeBatchInput(id: input.0.id, source: input.1,
                cached: record?.sourcePath == input.1.path ? record?.sensme : nil)
        }
        let work = Task.detached(priority: .utility) { [self] in
            _ = try await SensMeBatchAnalyzer.run(jobs) { outcome in
                guard let item = media[outcome.id] else { throw EnrichmentError("SensMe 任务配置无效") }
                try await self.checkpointAnalysis(outcome, media: item, total: jobs.count)
            }
        }
        analysisTask = work
        Task {
            do { try await work.value; updateAnalysisStatus(total: jobs.count) }
            catch is CancellationError { status = "分析已取消，已完成的结果保留" }
            catch { self.error = error.localizedDescription; status = "分析中断，已完成的结果保留" }
            analysisTask = nil; busy = false
        }
    }
    private func checkpointAnalysis(_ outcome: SensMeBatchOutcome, media: MediaFile, total: Int) throws {
        let key = SHA256.hash(data: Data(outcome.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let failureURL = directory.appendingPathComponent("SensMeFailures/" + key + ".json")
        switch outcome.value {
        case .analyzed(let result):
            try storeAnalysis(result, media: media, source: outcome.source)
            if FileManager.default.fileExists(atPath: failureURL.path) { try FileManager.default.removeItem(at: failureURL) }
            analysisFailures[outcome.id] = nil; analysisSummary.analyzed += 1
        case .cached:
            if FileManager.default.fileExists(atPath: failureURL.path) { try FileManager.default.removeItem(at: failureURL) }
            analysisFailures[outcome.id] = nil; analysisSummary.cached += 1
        case .failed(let message):
            let failure = SensMeTrackFailure(mediaID: outcome.id, sourcePath: outcome.source.path, message: message, failedAt: Date())
            try JSONEncoder().encode(failure).write(to: failureURL, options: .atomic)
            analysisFailures[outcome.id] = failure; analysisSummary.failed += 1
        }
        updateAnalysisStatus(total: total)
    }
    private func updateAnalysisStatus(total: Int) {
        status = LF("SensMe 已完成 %d/%d · 新分析 %d · 已验证 %d · 失败 %d",
                    analysisSummary.completed, total, analysisSummary.analyzed, analysisSummary.cached, analysisSummary.failed)
    }
    private func storeAnalysis(_ value: CachedSensMe, media: MediaFile, source: URL) throws {
        var record = records[media.id] ?? EnrichedTrack(mediaID: media.id, sourcePath: source.path, sourceSHA256: value.sourceSHA256)
        if let previous = record.sensme, previous.engineVersion != value.engineVersion || previous.sourceSHA256 != value.sourceSHA256 || previous.blob != value.blob {
            var history = record.sensmeHistory ?? []
            if !history.contains(where: { $0.engineVersion == previous.engineVersion && $0.sourceSHA256 == previous.sourceSHA256 && $0.blob == previous.blob }) {
                history.append(previous)
            }
            record.sensmeHistory = history
        }
        if record.sourceSHA256 != value.sourceSHA256 { record.candidates = []; record.approvedMetadata = nil; record.approvedArtwork = nil }
        record.sourceSHA256 = value.sourceSHA256; record.sourcePath = source.path; record.sensme = value
        try save(record)
    }
    func query(media: MediaFile?, source: URL?, probe: Bool = false) {
        guard !busy else { return }
        busy = true; status = probe ? "正在检测 Gracenote…" : "正在查询 Gracenote…"
        let title = queryTitle, artist = queryArtist, album = queryAlbum
        let runtime = runtime, credentials = credentials, working = directory.appendingPathComponent("Jobs")
        let work = Task.detached(priority: .utility) {
            let digest = try source.map(SourceDigest.sha256) ?? ""
            let response = try GracenoteEngine.query(title: title, artist: artist, album: album, probe: probe, runtime: runtime, credentials: credentials, workingDirectory: working)
            if let source, try SourceDigest.sha256(source) != digest { throw EnrichmentError("查询期间源文件改变，请重新查询") }
            return (response, digest)
        }
        queryTask = work
        Task {
            do {
                let (response, digest) = try await work.value
                if probe { status = "Gracenote SDK 就绪 · " + response.sdkVersion }
                else {
                    candidates = response.candidates; candidateMediaID = media?.id; resetDraft()
                    if let media, let source {
                        var record = records[media.id] ?? EnrichedTrack(mediaID: media.id, sourcePath: source.path, sourceSHA256: digest)
                        if record.sourceSHA256 != digest { record.sensme = nil; record.approvedMetadata = nil; record.approvedArtwork = nil }
                        record.sourceSHA256 = digest; record.sourcePath = source.path; record.candidates = candidates; try save(record)
                    }
                    status = String(format: L("Gracenote 返回 %d 个候选，请核对版本后采用"), candidates.count)
                }
            } catch is CancellationError { status = "查询已取消" }
            catch { self.error = error.localizedDescription; status = "Gracenote 查询未完成" }
            queryTask = nil; busy = false
        }
    }
    private func resetDraft() {
        selectedCandidateID = nil; selectedFields = []; selectedCoverID = nil
        coverPreview = nil; previewAssetID = nil; useSelectedCover = false
    }
    func chooseCandidate(_ candidate: GracenoteCandidate) {
        guard !busy else { return }
        resetDraft(); selectedCandidateID = candidate.id
        selectedFields = Set(candidate.metadata.availableFields)
        selectedCoverID = candidate.covers.min(by: { abs($0.width - 720) < abs($1.width - 720) })?.id
    }
    func loadDetails(_ candidate: GracenoteCandidate) {
        guard !busy, candidate.sdkData != nil else { return }
        busy = true; status = "正在获取完整专辑信息…"
        let runtime = runtime, credentials = credentials, working = directory.appendingPathComponent("Jobs")
        let work = Task.detached(priority: .utility) {
            (try GracenoteEngine.query(title: candidate.metadata.title, artist: candidate.metadata.artist, album: candidate.metadata.album,
                                      runtime: runtime, credentials: credentials, workingDirectory: working, detail: candidate), "")
        }
        queryTask = work
        Task {
            do {
                let (response, _) = try await work.value
                guard let detail = response.candidates.first(where: { $0.metadata.title.caseInsensitiveCompare(candidate.metadata.title) == .orderedSame && (candidate.metadata.track.isEmpty || $0.metadata.track == candidate.metadata.track) }) ?? response.candidates.first else { throw EnrichmentError("此发行版没有返回完整信息，请重新查询") }
                let updated = GracenoteCandidate(id: candidate.id, metadata: candidate.metadata.merging(detail.metadata), artwork: detail.artwork, sdkData: detail.sdkData, fullResult: detail.fullResult)
                if let i = candidates.firstIndex(where: { $0.id == candidate.id }) { candidates[i] = updated }
                if let id = candidateMediaID, var record = records[id] { record.candidates = candidates; try save(record) }
                busy = false; chooseCandidate(updated); status = "完整信息已载入，请勾选要采用的字段与封面"
            } catch is CancellationError { status = "查询已取消" }
            catch { self.error = error.localizedDescription; status = "完整信息查询未完成" }
            queryTask = nil; busy = false
        }
    }
    func previewCover(_ asset: GracenoteCoverAsset) {
        guard !busy else { return }
        busy = true; status = "正在下载封面预览…"; useSelectedCover = false
        let work = Task { try await GracenoteArtworkDownload.download(asset) }; coverTask = work
        Task {
            do {
                coverPreview = try await work.value; previewAssetID = asset.id
                useSelectedCover = true; status = "封面已载入，采用前可取消勾选"
            } catch is CancellationError { status = "封面下载已取消" }
            catch { self.error = error.localizedDescription; status = "封面下载未完成" }
            coverTask = nil; busy = false
        }
    }
    func artwork(for mediaID: String) -> EnrichmentArtwork? {
        guard let key = records[mediaID]?.approvedArtwork, key.count == 64, key.allSatisfy({ $0.isHexDigit }),
              let data = try? Data(contentsOf: directory.appendingPathComponent("Artwork/" + key)),
              let artwork = try? EnrichmentArtwork(data: data), artwork.sha256 == key else { return nil }
        return artwork
    }
    func approve(_ candidate: GracenoteCandidate, for media: MediaFile, metadata: MetadataPatch, artwork: EnrichmentArtwork?) throws {
        guard candidateMediaID == media.id, var record = records[media.id], candidates.contains(where: { $0.id == candidate.id }) else { throw EnrichmentError("请重新选择对应曲目的候选") }
        if !metadata.isEmpty { record.approvedMetadata = metadata }
        if let artwork {
            let folder = directory.appendingPathComponent("Artwork")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try artwork.data.write(to: folder.appendingPathComponent(artwork.sha256), options: .atomic)
            record.approvedArtwork = artwork.sha256
        }
        try save(record); status = "已保存所选标签与封面；传输时写入副本"
    }
    func cancel() { analysisTask?.cancel(); queryTask?.cancel(); coverTask?.cancel() }
    func transferEnrichments(_ items: [MusicTransferItem]) -> [String: TransferEnrichment] {
        var byPath: [String: EnrichedTrack] = [:]
        for value in records.values { byPath[value.sourcePath] = value }
        return items.reduce(into: [:]) { result, item in
            guard ["mp3", "flac"].contains(item.source.pathExtension.lowercased()), let record = byPath[item.source.path], record.sensme != nil || record.approvedMetadata != nil || record.approvedArtwork != nil else { return }
            result[item.id] = .init(sourceSHA256: record.sourceSHA256, sensme: record.sensme?.blob, metadata: record.approvedMetadata, artwork: artwork(for: record.mediaID))
        }
    }
}
