import SwiftUI
import LibraryDomain
import MusicEnrichment

struct MusicEnrichmentView: View {
    @ObservedObject var model: MusicEnrichmentModel
    @ObservedObject var library: AppModel
    @State private var search = ""
    @State private var showSettings = false
    private var music: [MediaFile] { library.files.filter { $0.available && !$0.isDiscImage } }
    private var filtered: [MediaFile] {
        music.filter { search.isEmpty || ($0.title + " " + $0.artistDisplay + " " + $0.albumDisplay).localizedCaseInsensitiveContains(search) }
    }
    private var focused: MediaFile? { music.first { $0.id == model.focusedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Label(L("SensMe 原生引擎可用"), systemImage: "checkmark.circle")
                Label(L(model.credentialsReady ? "Media Go 授权已导入" : "Gracenote 需要本机授权"), systemImage: model.credentialsReady ? "checkmark.circle" : "key")
                Spacer()
                Button(L("引擎设置…")) { showSettings = true }
            }.font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                selection.frame(minWidth: 280, idealWidth: 330, maxWidth: 400)
                Divider()
                ScrollView { details.frame(maxWidth: .infinity, alignment: .leading) }.frame(minWidth: 310, maxWidth: .infinity)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(L(model.status)).font(.callout).foregroundStyle(accent).lineLimit(2)
                Spacer()
                if model.busy { Button(L("取消")) { model.cancel() } }
            }.frame(minHeight: 28)
            Text(L("结果保存在本机。所选标签与封面更新曲库显示；传到 Walkman 时写入 MP3/FLAC 副本，原文件保留。")).font(.caption).foregroundStyle(.secondary)
            Text(L("DSD 等系统不支持的格式需要本机 FFmpeg。失败曲目会保留原因，可重新选择后重试。")).font(.caption).foregroundStyle(.secondary)
        }.padding(24)
        .sheet(isPresented: $showSettings) { settings }
        .alert(L("操作未完成"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("知道了"), role: .cancel) { model.error = nil }
        } message: { Text(L(model.error ?? "")) }
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("搜索待分析的音乐"), text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Button(L("全选搜索结果")) { model.selectedIDs.formUnion(filtered.map(\.id)) }
                Button(L("取消选择")) { model.selectedIDs = [] }
                Spacer()
                Text(LF("已选 %d 首", model.selectedIDs.count)).font(.caption).foregroundStyle(.secondary)
            }.font(.caption).disabled(model.busy)
            List(filtered) { media in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(get: { model.selectedIDs.contains(media.id) }, set: { if $0 { model.selectedIDs.insert(media.id) } else { model.selectedIDs.remove(media.id) } })).labelsHidden().toggleStyle(.checkbox)
                    Button { model.select(media) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(media.title).lineLimit(1).foregroundStyle(model.focusedID == media.id ? accent : .primary)
                            Text(uiArtist(media)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let result = model.records[media.id]?.sensme {
                                Text(result.summary.bpm.map { String(format: "SensMe · %.1f BPM", $0) } ?? "SensMe ✓").font(.caption2).foregroundStyle(accent)
                            }
                            if let failure = model.analysisFailures[media.id] {
                                Text(LF("分析失败：%@", L(failure.message))).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                            }
                            if model.records[media.id]?.approvedMetadata != nil || model.records[media.id]?.approvedArtwork != nil { Text(L("已采用补全")).font(.caption2).foregroundStyle(accent) }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(.vertical, 4)
            }.listStyle(.inset).scrollContentBackground(.hidden).disabled(model.busy)
            Button { library.analyzeSelectedMusic() } label: { Label(L("分析所选音乐"), systemImage: "waveform.path") }
                .negiProminentButton().disabled(model.busy || !model.sensmeReady || (model.selectedIDs.isEmpty && focused == nil))
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("SensMe", systemImage: "waveform").font(.headline)
                if let focused {
                    Text(focused.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let result = model.records[focused.id]?.sensme {
                        Text(result.summary.bpm.map { String(format: "%.2f BPM", $0) } ?? L("节奏未确定")).font(.title2.monospacedDigit()).foregroundStyle(accent)
                        Text(result.engineVersion + " · " + LF("%d 个分析分块", result.summary.chunks.count)).font(.caption).foregroundStyle(.secondary)
                        Text(result.summary.chunks.map(\.name).joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    } else { Text(L("尚未分析此曲目")).foregroundStyle(.secondary) }
                } else { Text(L("选择曲目可查看分析结果。也可直接输入文字测试 Gracenote 查询。")).foregroundStyle(.secondary) }
                Text(L("SensMe 在本机原生分析，无需外部引擎；音频独立转换为 44.1 kHz / 16-bit 双声道，不经过播放 EQ。")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label(L("Gracenote 标签补全"), systemImage: "text.badge.checkmark").font(.headline)
                TextField(L("歌曲标题"), text: $model.queryTitle).textFieldStyle(.roundedBorder)
                TextField(L("艺人"), text: $model.queryArtist).textFieldStyle(.roundedBorder)
                TextField(L("专辑（可留空）"), text: $model.queryAlbum).textFieldStyle(.roundedBorder)
                HStack {
                    Button(L("查询候选")) { library.queryGracenote() }.negiProminentButton()
                        .disabled(!model.credentialsReady || !model.gracenoteReady || model.queryTitle.isEmpty || (model.queryArtist.isEmpty && model.queryAlbum.isEmpty))
                    Button(L("检测 SDK")) { library.queryGracenote(probe: true) }.disabled(!model.credentialsReady || !model.gracenoteReady)
                }
                Text(L("仅发送标题、艺人与专辑文字，不上传本地音频。候选需手动核对，版本与重发行信息可能不同。")).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            ForEach(model.candidates) { candidate in
                GracenoteCandidateView(model: model, library: library, candidate: candidate, focused: focused)
            }
        }.padding(.trailing, 6)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Gracenote SDK 设置")).font(.title2.bold())
            Text(model.engineDirectory.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Button(L("选择引擎文件夹…")) { model.chooseRuntime() }.disabled(model.busy)
            Text(L("SensMe 使用内置原生分析器。此文件夹仅供可选的 Gracenote SDK 及其外部运行环境使用，不会自动开启网络查询。")).font(.callout).foregroundStyle(.secondary)
            Divider()
            Button(L("导入 Media Go 本机授权…")) { model.chooseMediaGo() }.disabled(model.busy)
            Text(L("授权和注册用户信息仅保存到本机应用数据，源码包不包含这些凭据。")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Button(L("完成")) { showSettings = false }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 590, height: 350)
    }
}
