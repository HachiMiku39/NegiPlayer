import SwiftUI
import AppKit
import AudioCore
import LyricCore
import MediaIO

struct LyricsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: PlaybackSession
    @State private var exactTime = ""
    @State private var offsetMS = "0"
    @State private var peaks: [Float] = []
    @State private var analysisStatus = ""
    @State private var markerOrigins: [UUID: Int64] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if playback.current == nil {
                VStack(spacing: 16) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(accent)
                    Text(L("跟随音乐，记下每一个字")).font(.title2)
                    Text(L("先从音乐库载入曲目。歌词草稿会绑定到具体音频文件版本，\n并共享播放器时钟。")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.lyricReady {
                VStack(spacing: 16) {
                    if model.draftStatus.hasPrefix("正在") { ProgressView() }
                    Text(L(model.draftStatus)).foregroundStyle(.secondary)
                    Text(L("仅校验当前曲目；音乐文件保持只读。")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tools
                if model.needsAudioReview {
                    HStack { Text(L("音频版本已改变，歌词时间轴需要核对。")).foregroundStyle(.orange); Spacer(); Button(L("确认重新关联当前音频")) { model.confirmAudioBinding() } }.font(.caption)
                }
                if !model.document.warnings.isEmpty { Text(L(model.document.warnings.joined(separator: "\n"))).font(.caption).foregroundStyle(.orange) }
                if model.document.rows.isEmpty {
                    Text(L("粘贴歌词正文，或导入 TXT / LRC / Enhanced LRC / SRT / Negi 工程")).font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $model.lyricText).font(.system(size: 16)).frame(minHeight: 180).scrollContentBackground(.hidden).padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    Button(L("建立打轴草稿")) { model.prepareLyrics() }.negiProminentButton()
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 15) {
                                ForEach(Array(model.document.rows.enumerated()), id: \.element.id) { index, row in
                                    rowView(index, row).id(row.id)
                                }
                            }.padding(.vertical, 8)
                        }
                        .onChange(of: model.selectedRow) { _, row in
                            if model.document.rows.indices.contains(row) { withAnimation { proxy.scrollTo(model.document.rows[row].id, anchor: .center) } }
                        }
                    }
                    timingControls
                    timeline
                    HStack {
                        Text(L(model.draftStatus)).foregroundStyle(accent)
                        Spacer()
                        Text(LF("%d 行 · 正 offset 表示延后 · 纳秒存储",model.document.rows.count)).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        }.padding(24)
        .task(id: playback.current?.id) {
            peaks = []; analysisStatus = "正在分析 PCM 波形…"
            guard let media = playback.current, !media.isDSD, let url = try? model.url(for: media) else { analysisStatus = "没有 PCM 波形"; return }
            do {
                let value = try await PCMAnalysis().peaks(for: url, bins: 1000)
                if !Task.isCancelled { peaks = value; analysisStatus = "独立 PCM 分析 · 不修改音频" }
            } catch { analysisStatus = "波形分析不可用：\(error.localizedDescription)" }
        }
        .onChange(of: model.selectedRow) { _, _ in updateTime() }
        .onChange(of: model.selectedToken) { _, _ in updateTime() }
        .onChange(of: model.document.revision) { _, _ in updateTime() }
        .onAppear { updateTime() }
    }
    var tools: some View {
        HStack {
            Picker(L("打轴方式"), selection: Binding(get: { model.document.mode }, set: { model.changeMode($0) })) {
                Text(L("逐句")).tag(TimingMode.line); Text(L("逐字")).tag(TimingMode.character); Text(L("逐词")).tag(TimingMode.word)
            }.pickerStyle(.segmented).frame(width: 220)
            Button(L("导入…")) { model.importLyrics() }
            Menu(L("导出")) {
                Button(L("LRC / Enhanced LRC…")) { model.exportLyrics(kind: "lrc") }
                Button(L("完整歌词工程…")) { model.exportLyrics(kind: "project") }
                Button(L("纯文本 TXT…")) { model.exportLyrics(kind: "txt") }
                if model.document.importedProject != nil { Button(L("回导 Negi 草稿…")) { model.exportLyrics(kind: "negi") } }
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo)
            Button(L("下一处未打点")) { model.nextUntimed() }
            Button(L("T 打点")) { model.stamp(eventUptime: ProcessInfo.processInfo.systemUptime, advance: true) }.negiProminentButton()
        }.padding(10).negiGlass(14)
    }
    func rowView(_ index: Int, _ row: LyricRow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index+1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                Button { model.select(index, model.document.mode == .line ? nil : 0) } label: {
                    Text(row.start.map { durationText(model.document.displayTime($0).seconds) } ?? L("未打点")).font(.caption.monospacedDigit()).foregroundStyle(row.start == nil ? .secondary : accent)
                }.buttonStyle(.plain).frame(width: 60)
                Text(row.text.isEmpty ? L("（空行）") : row.text).font(.system(size: 19, weight: model.document.activeRow(at: playback.position) == row.id ? .semibold : .regular))
                    .foregroundStyle(!model.needsAudioReview && model.document.activeRow(at: playback.position) == row.id ? accent : Color.primary.opacity(0.85)).textSelection(.enabled)
                Spacer()
            }.contentShape(Rectangle()).onTapGesture { model.select(index, model.document.mode == .line ? nil : 0) }
            if model.document.mode != .line {
                TokenFlow(spacing: 6) {
                    ForEach(Array(row.tokens.enumerated()), id: \.element.id) { tokenIndex, token in
                        let selected = model.selectedRow == index && model.selectedToken == tokenIndex
                        let active = isActive(tokenIndex, row)
                        StampChip(text: token.text, time: token.start.map { String(format: "%.3f", model.document.displayTime($0).seconds) } ?? "—", selected: selected, active: active,
                                  select: { model.select(index, tokenIndex) },
                                  stamp: { event in if playback.isPlaying { model.dragStamp(row: index, token: tokenIndex, eventUptime: event.timestamp) } else { model.select(index, tokenIndex) } },
                                  end: { model.endDrag() })
                            .frame(width: max(48, min(220, CGFloat(token.text.count)*13+18)), height: 46)
                    }
                }.padding(.leading, 98)
            }
        }.padding(12).background(model.selectedRow == index ? accent.opacity(0.07) : Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
    }
    func isActive(_ index: Int, _ row: LyricRow) -> Bool {
        guard let t = row.tokens[index].start else { return false }
        let now = playback.position
        let end = row.tokens.dropFirst(index+1).compactMap(\.start).first
        return now >= model.document.displayTime(t).seconds && now < (end.map { model.document.displayTime($0).seconds } ?? row.end.map { model.document.displayTime($0).seconds } ?? (model.document.displayTime(t).seconds+2))
    }
    var timingControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L("选中时间（基础秒）")).font(.caption)
                TextField(L("未打点"), text: $exactTime).textFieldStyle(.roundedBorder).frame(width: 110).onSubmit { applyTime() }
                Button(L("应用")) { applyTime() }
                Button(L("−10 ms")) { model.adjustSelected(-10) }
                Button(L("+10 ms")) { model.adjustSelected(10) }
                Button(L("清除")) { model.setSelectedBase(nil) }
                Spacer()
                Text(L("全局偏移 ms")).font(.caption)
                TextField("0", text: $offsetMS).textFieldStyle(.roundedBorder).frame(width: 80).onSubmit { applyOffset() }
                Button(L("应用偏移")) { applyOffset() }
            }
            Text(L("播放时按 T 或拖过单元打点；暂停后选择并精修。拖歌词标记只改歌词，点击波形改变播放位置。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    func updateTime() {
        if let t = model.selectedTime { exactTime = NSDecimalNumber(decimal: Decimal(t.nanoseconds)/1_000_000_000).stringValue } else { exactTime = "" }
        offsetMS = NSDecimalNumber(decimal: Decimal(model.document.offset.nanoseconds)/1_000_000).stringValue
    }
    func applyTime() {
        do { model.setSelectedBase(exactTime.isEmpty ? nil : try .decimal(exactTime)) } catch { model.error = error.localizedDescription }
    }
    func applyOffset() {
        guard let n = Decimal(string: offsetMS), abs(NSDecimalNumber(decimal: n).doubleValue) < 1_000_000_000 else { model.error = "无效的 offset"; return }
        let seconds = NSDecimalNumber(decimal: n/1000).stringValue
        do { let value = try LyricTime.decimal(seconds); model.edit { $0.offset = value } } catch { model.error = error.localizedDescription }
    }
    var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("歌词时间轴")).font(.headline)
                Text(L(analysisStatus)).font(.caption).foregroundStyle(.secondary)
                Spacer(); Text(L("缩放")).font(.caption); Slider(value: $model.timelineZoom, in: 1...8).frame(width: 120)
            }
            GeometryReader { geometry in
                let width = max(geometry.size.width, geometry.size.width*model.timelineZoom)
                let duration = max(1, playback.duration)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.black.opacity(0.15))
                            .onTapGesture { point in model.seek(Double(point.x/width)*duration) }
                        Canvas { context, size in
                            if !peaks.isEmpty {
                                for (i, peak) in peaks.enumerated() {
                                    let x = CGFloat(i)/CGFloat(peaks.count)*width
                                    let h = CGFloat(min(1, peak))*38
                                    var line = Path(); line.move(to: CGPoint(x: x, y: 66-h)); line.addLine(to: CGPoint(x: x, y: 66+h))
                                    context.stroke(line, with: .color(accent.opacity(0.34)), lineWidth: max(1,width/CGFloat(peaks.count)*0.65))
                                }
                            }
                        }.allowsHitTesting(false)
                        ForEach(0..<11, id: \.self) { i in
                            Text(durationText(duration*Double(i)/10)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).position(x: width*CGFloat(i)/10+15, y: 10)
                        }
                        ForEach(Array(model.document.rows.enumerated()), id: \.element.id) { index, row in
                            if let start = row.start {
                                let display = model.document.displayTime(start).seconds
                                if display >= 0 && display <= duration {
                                    VStack(spacing: 2) { Text("\(index+1)").font(.caption2); RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 7, height: 45) }
                                        .foregroundStyle(accent).frame(width: 24, height: 64)
                                        .position(x: CGFloat(display/duration)*width, y: 118)
                                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                                            if markerOrigins[row.id] == nil { markerOrigins[row.id] = start.nanoseconds; model.beginDrag() }
                                            let original = markerOrigins[row.id] ?? start.nanoseconds
                                            let delta = Int64(Double(value.translation.width/width)*duration*1_000_000_000)
                                            model.edit(checkpoint: false) { $0.rows[index].start = .init(nanoseconds: original+delta) }
                                        }.onEnded { _ in markerOrigins[row.id] = nil; model.endDrag() })
                                        .onTapGesture { model.select(index, nil) }
                                }
                            }
                        }
                        Rectangle().fill(Color.primary.opacity(0.9)).frame(width: 1, height: 150).position(x: CGFloat(playback.position/duration)*width, y: 75).allowsHitTesting(false)
                    }.frame(width: width, height: 155).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.frame(height: 165)
            let outOfRange = model.document.rows.filter { r in
                guard let time = r.start else { return false }; let t = model.document.displayTime(time).seconds; return t < 0 || t > playback.duration
            }.count
            if outOfRange > 0 { Text(LF("%d 行在媒体范围外；已保留在草稿，未显示在波形范围内。",outOfRange)).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct TokenFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { arrange(proposal.width ?? 600, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (i, point) in result.points.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX+point.x, y: bounds.minY+point.y), proposal: .unspecified) }
    }
    func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0; var y: CGFloat = 0; var lineHeight: CGFloat = 0; var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x+size.width > width && x > 0 { x = 0; y += lineHeight+spacing; lineHeight = 0 }
            points.append(.init(x: x, y: y)); x += size.width+spacing; lineHeight = max(lineHeight, size.height)
        }
        return (.init(width: width, height: y+lineHeight), points)
    }
}

struct StampChip: NSViewRepresentable {
    var text: String; var time: String; var selected: Bool; var active: Bool
    var select: () -> Void; var stamp: (NSEvent) -> Void; var end: () -> Void
    func makeNSView(context: Context) -> ChipView { ChipView() }
    func updateNSView(_ view: ChipView, context: Context) {
        view.text = text; view.time = time; view.selected = selected; view.active = active
        view.selectAction = select; view.stampAction = stamp; view.endAction = end; view.needsDisplay = true
    }
}
final class ChipView: NSView {
    var text = ""; var time = ""; var selected = false; var active = false
    var selectAction: (() -> Void)?; var stampAction: ((NSEvent) -> Void)?; var endAction: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag, .inVisibleRect], owner: self))
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(calibratedRed: 0.224, green: 0.773, blue: 0.733, alpha: 1)
        (selected || active ? color.withAlphaComponent(0.18) : NSColor.labelColor.withAlphaComponent(0.045)).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6); shape.fill()
        if selected { color.withAlphaComponent(0.6).setStroke(); shape.stroke() }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: NSRect(x: 4, y: 5, width: bounds.width-8, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: active ? color : NSColor.labelColor, .paragraphStyle: paragraph])
        (time as NSString).draw(in: NSRect(x: 4, y: 28, width: bounds.width-8, height: 15), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); selectAction?(); stampAction?(event) }
    override func mouseEntered(with event: NSEvent) { if NSEvent.pressedMouseButtons & 1 != 0 { stampAction?(event) } }
    override func mouseUp(with event: NSEvent) { endAction?() }
}
