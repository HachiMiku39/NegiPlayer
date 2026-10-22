import SwiftUI
import AppKit
import LibraryDomain
import MusicEnrichment

struct GracenoteCandidateView: View {
    @ObservedObject var model: MusicEnrichmentModel
    @ObservedObject var library: AppModel
    let candidate: GracenoteCandidate
    let focused: MediaFile?
    private var expanded: Bool { model.selectedCandidateID == candidate.id }
    private var canApply: Bool { focused != nil && model.candidateMediaID == focused?.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.metadata.album).font(.headline).textSelection(.enabled)
                    Text(candidate.metadata.title + " · " + candidate.metadata.artist).font(.callout)
                    Text([candidate.metadata.year, candidate.metadata[.label], candidate.metadata.genre].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !expanded {
                    Button(L("选择发行版")) {
                        model.chooseCandidate(candidate)
                        if candidate.fullResult != true && candidate.sdkData != nil { model.loadDetails(candidate) }
                    }.disabled(model.busy)
                } else { Label(L("已选择"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(accent) }
            }
            if expanded {
                Divider()
                HStack {
                    Text(L("采用的标签字段")).font(.subheadline.bold())
                    Spacer()
                    Button(L("全选字段")) { model.selectedFields = Set(candidate.metadata.availableFields) }
                    Button(L("取消选择字段")) { model.selectedFields = [] }
                }.font(.caption).disabled(model.busy)
                ForEach(candidate.metadata.availableFields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(L(field.label), isOn: Binding(get: { model.selectedFields.contains(field) }, set: { if $0 { model.selectedFields.insert(field) } else { model.selectedFields.remove(field) } }))
                            .toggleStyle(.checkbox).frame(width: 130, alignment: .leading)
                        Text(candidate.metadata[field]).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.disabled(model.busy)
                }
                Text(L("未勾选的字段和未返回的信息保留当前值。")).font(.caption).foregroundStyle(.secondary)
                coverEditor
                if canApply {
                    Button(L("采用所选标签与封面")) { library.applyGracenote(candidate) }.negiProminentButton()
                        .disabled(model.busy || (model.selectedFields.isEmpty && !(model.useSelectedCover && model.previewAssetID == model.selectedCoverID)))
                } else { Text(L("选择本地曲目后重新查询，才能采用到曲库。")).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(expanded ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var coverEditor: some View {
        Divider()
        Text(L("专辑封面")).font(.subheadline.bold())
        if candidate.covers.isEmpty {
            Text(L("此发行版没有返回封面，保留现有封面。")).font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                Picker(L("封面尺寸"), selection: Binding(get: { model.selectedCoverID ?? "" }, set: { model.selectedCoverID = $0; model.useSelectedCover = false })) {
                    ForEach(candidate.covers) { asset in Text(asset.label).tag(asset.id) }
                }.frame(maxWidth: 280)
                Button(L("预览封面")) {
                    if let asset = candidate.covers.first(where: { $0.id == model.selectedCoverID }) { model.previewCover(asset) }
                }
            }.disabled(model.busy)
            if model.previewAssetID == model.selectedCoverID, let artwork = model.coverPreview, let image = NSImage(data: artwork.data) {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 160, height: 160).accessibilityLabel(L("封面预览"))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(artwork.width) × \(artwork.height) · \(ByteCountFormatter.string(fromByteCount: Int64(artwork.data.count), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        Toggle(L("采用这张封面"), isOn: $model.useSelectedCover).disabled(model.busy)
                        Text(L("取消勾选可保留原封面。采用后先更新本机显示，传输时写入副本。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else { Text(L("按需下载预览，不会自动替换现有封面。")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
