import SwiftUI
import LibraryDomain
import FileOperations

struct WalkmanTransferView: View {
    @ObservedObject var transfer: WalkmanTransferModel
    @ObservedObject var library: AppModel
    @State private var showLibrary = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            destination
            HStack(spacing: 12) {
                Button { transfer.chooseFiles() } label: { Label(L("添加文件或文件夹…"), systemImage: "folder.badge.plus") }
                Button { showLibrary = true } label: { Label(L("从曲库选择…"), systemImage: "music.note.list") }.disabled(library.availableFileCount == 0)
                Spacer()
                Text(LF("%d 首 · %@", transfer.items.count, bytes(transfer.selectedBytes))).font(.callout).foregroundStyle(.secondary)
                Button(L("清空")) { transfer.clear() }.disabled(transfer.items.isEmpty)
            }.disabled(transfer.busy || transfer.adding)
            selectionList
            HStack(spacing: 24) {
                Picker(L("同名文件"), selection: $transfer.policy) {
                    Text(L("跳过同名文件")).tag(TransferCollisionPolicy.skipExisting)
                    Text(L("保留两份（自动编号）")).tag(TransferCollisionPolicy.keepBoth)
                }.frame(width: 300)
                Toggle(L("复制后校验 SHA-256"), isOn: $transfer.verify)
                Spacer()
            }.disabled(transfer.busy || transfer.adding)
            Toggle(L("携带 SensMe 与补全标签（MP3/FLAC）"), isOn: $transfer.includeEnrichment).font(.callout).disabled(transfer.busy || transfer.adding)
            if transfer.incompatibleCount > 0 {
                Label(LF("%d 首的格式未获设备声明支持，请移除后传输", transfer.incompatibleCount), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            progressArea
            HStack {
                Text(L("复制到 MUSIC，保留目录与标签。完成后请在 Finder 中弹出两个存储卷。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if transfer.busy {
                    Button(L(transfer.cancelling ? "正在取消…" : "取消传输")) { transfer.cancel() }.disabled(transfer.cancelling)
                } else {
                    Button { transfer.start() } label: { Label(L("开始传输"), systemImage: "arrow.down.to.line") }
                        .negiProminentButton().disabled(transfer.adding || transfer.items.isEmpty || transfer.selectedVolume == nil || transfer.incompatibleCount > 0)
                }
            }
        }.padding(24)
        .onAppear { transfer.refreshVolumes() }
        .sheet(isPresented: $showLibrary) { WalkmanLibraryPicker(library: library, transfer: transfer) }
        .alert(L("操作未完成"), isPresented: Binding(get: { transfer.error != nil }, set: { if !$0 { transfer.error = nil } })) {
            Button(L("知道了"), role: .cancel) { transfer.error = nil }
        } message: { Text(L(transfer.error ?? "")) }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("目标存储"), systemImage: "externaldrive.badge.plus").font(.headline)
                Spacer()
                if transfer.discovering { ProgressView().controlSize(.small) }
                Button(L("选择存储…")) { transfer.chooseStorage() }.disabled(transfer.busy)
                Button(L("刷新设备")) { transfer.refreshVolumes() }.disabled(transfer.busy || transfer.discovering)
                Button(L("在 Finder 中打开")) { transfer.revealDestination() }.disabled(transfer.selectedVolume == nil)
            }
            if transfer.volumes.isEmpty {
                Label(L(transfer.discovering ? "正在查找 Walkman…" : "未发现 Walkman，请连接设备并开启 USB 存储模式"), systemImage: "cable.connector").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ForEach(transfer.volumes) { volume in
                        Button { transfer.selectedVolumeID = volume.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: volume.isCard ? "sdcard" : "ipod").font(.title2).foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(volume.name + " · " + L(volume.isCard ? "SD 卡" : "机身存储")).font(.headline)
                                    Text(volume.model + " · " + LF("可用 %@", bytes(volume.availableBytes))).font(.caption).foregroundStyle(.secondary)
                                    Text(volume.musicDirectory.path).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: transfer.selectedVolumeID == volume.id ? "checkmark.circle.fill" : "circle").foregroundStyle(accent)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(accent.opacity(transfer.selectedVolumeID == volume.id ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(transfer.selectedVolumeID == volume.id ? 0.8 : 0.15)))
                        }.buttonStyle(.plain).disabled(transfer.busy)
                    }
                }
                if transfer.selectedVolume == nil { Text(L("原目标已断开，请重新选择存储")).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private var selectionList: some View {
        Group {
            if transfer.items.isEmpty {
                ContentUnavailableView(L("选择要带走的音乐"), systemImage: "music.note", description: Text(L("从曲库勾选曲目，或添加本地音乐文件与文件夹。")))
            } else {
                List {
                    ForEach(transfer.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "music.note").foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.source.lastPathComponent).lineLimit(1)
                                Text("MUSIC/" + ((try? MusicTransfer.safeRelativePath(item.relativePath)) ?? item.relativePath)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let volume = transfer.selectedVolume, !volume.extensions.contains(item.source.pathExtension.lowercased()) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(L("设备未声明支持此格式")) }
                            Text(bytes(item.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { transfer.remove(item.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).disabled(transfer.busy || transfer.adding).help(L("移除"))
                        }.padding(.vertical, 3)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let progress = transfer.progress {
                ProgressView(value: progress.fraction)
                HStack {
                    Text(L(transfer.busy ? (progress.phase == .verifying ? "校验中" : "复制中") : "已处理") + " · " + progress.filename).lineLimit(1)
                    Spacer()
                    Text("\(progress.completedFiles)/\(transfer.items.count) · \(Int(progress.fraction * 100))% ").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            } else if transfer.busy || transfer.adding { ProgressView().controlSize(.small) }
            if !transfer.status.isEmpty { Text(transfer.status).font(.callout).foregroundStyle(accent) }
        }.frame(minHeight: 40)
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

private struct WalkmanLibraryPicker: View {
    @ObservedObject var library: AppModel
    @ObservedObject var transfer: WalkmanTransferModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected = Set<String>()
    private var candidates: [MediaFile] { library.files.filter { $0.available && !$0.isDiscImage }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending } }
    private var filtered: [MediaFile] { candidates.filter { search.isEmpty || ($0.title + " " + $0.artistDisplay + " " + $0.albumDisplay + " " + $0.relativePath).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("从曲库选择音乐")).font(.title2.bold())
            TextField(L("搜索音乐库"), text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Button(L("全选搜索结果")) { selected.formUnion(filtered.map(\.id)) }
                Button(L("取消选择")) { selected = [] }
                Spacer()
                Text(LF("已选 %d 首", selected.count)).foregroundStyle(.secondary)
            }
            List(filtered) { media in
                Toggle(isOn: Binding(get: { selected.contains(media.id) }, set: { if $0 { selected.insert(media.id) } else { selected.remove(media.id) } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.title)
                        Text(uiArtist(media) + " · " + uiAlbum(media)).font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox).padding(.vertical, 4)
            }.listStyle(.inset)
            HStack {
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("添加到传输列表")) {
                    library.addToWalkman(candidates.filter { selected.contains($0.id) }); dismiss()
                }.negiProminentButton().disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 650, height: 570)
    }
}
