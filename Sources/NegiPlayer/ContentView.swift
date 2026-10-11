import SwiftUI
import AppKit
import LibraryDomain
import AudioCore
import LyricCore

func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    let n = Int(seconds); return String(format: "%d:%02d", n/60, n%60)
}

func uiArtist(_ f:MediaFile)->String { f.artists.isEmpty ? L("未知艺人") : f.artistDisplay }
func uiAlbum(_ f:MediaFile)->String { f.album.isEmpty ? L("未标记专辑") : f.album }

@MainActor func audioPath(_ p:PlaybackSession)->String {
    guard let current=p.current else { return L("选择本地音乐开始播放") }
    let device=p.devices.first{$0.id==p.actualDeviceID}?.name ?? L("设备待确认")
    var path=current.codec+(current.sampleRate>0 ? " "+String(Int(current.sampleRate))+" Hz" : "")+" → PCM"
    if abs(p.loudness.gainDB)>0.0001 { path+=LF(" · 增益 %+.1f dB",p.loudness.gainDB) }
    if p.eqEnabled { path+=" · EQ" }
    path+=" · "+L(p.isMuted ? "静音" : "软件音量")
    if p.outputRate>0 && abs(current.sampleRate-p.outputRate)>1 { path+=" · "+L("采样率转换") }
    return path+" → "+device+" · "+String(Int(p.outputRate))+" Hz "+L("（系统混音）")
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: PlaybackSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 210)
                VStack(spacing: 0) {
                    if model.page != "playing" { header; Divider() }
                    Group {
                        switch model.page {
                        case "playing": NowPlayingView(model: model, playback: playback)
                        case "images": discImagesView
                        case "lyrics": LyricsView(model: model, playback: playback)
                        case "output": outputView
                        case "lan": LANConnectionView(host:model.lan)
                        case "appearance": VStack(alignment:.leading,spacing:20) { Text(L("外观与语言")).font(.title2.bold()); AppearanceControls(); Spacer() }.padding(24)
                        case "roots": rootsView
                        case "database": databaseView
                        case "artists": artistsView
                        case "albums": albumsView
                        default: tracksView(model.filtered)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.showQueue { Divider(); queueView.frame(width: 260) }
            }
            if model.page != "playing" { playerBar }
        }
        .background(NegiBackground())
        .tint(accent)
        .alert(L("操作未完成"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("知道了"), role: .cancel) { model.error = nil }
        } message: { Text(L(model.error ?? "")) }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(accent)
                    .overlay(alignment: .bottomTrailing) { RoundedRectangle(cornerRadius: 1).fill(pinkAccent).frame(width: 3, height: 8).rotationEffect(.degrees(-18)).offset(x: 3, y: 3) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("NEGI PLAYER")).font(.system(size: 13, weight: .semibold, design: .rounded)).tracking(1)
                    Text(L("音乐 · 收藏 · 创作")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 24).padding(.horizontal, 18)
            ScrollView { VStack(alignment:.leading,spacing:8) {
            Text(L("音乐库")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            nav("playing", "正在播放", "play.square")
            nav("albums", "专辑", "square.grid.2x2")
            nav("artists", "艺人", "person.2")
            nav("tracks", "所有曲目", "music.note.list")
            nav("roots", "文件夹", "folder")
            nav("images", "光盘镜像", "opticaldisc")
            nav("lan", "iOS 连接", "iphone.and.arrow.forward")
            Text(L("工作室")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 20)
            nav("lyrics", "歌词与时间轴", "text.alignleft")
            nav("output", "输出与均衡器", "slider.horizontal.3")
            nav("database", "曲库管理", "externaldrive")
            nav("appearance", "外观与语言", "paintpalette")
            } }.scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format:L("%d 首曲目"),model.musicFileCount)).font(.callout)
                Text(L("本地优先 · 开发预览 0.4")).font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.negiGlass(22).padding(12)
    }
    func nav(_ key: String, _ title: String, _ icon: String) -> some View {
        Button { model.page = key } label: {
            Label(L(title), systemImage: icon).font(.system(size: 13, weight: model.page == key ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11).padding(.horizontal, 14)
                .foregroundStyle(model.page == key ? accent : Color.primary.opacity(0.72))
                .background(model.page == key ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.horizontal, 10)
    }
    var title: String {
        ["albums": "专辑", "artists": "艺人", "tracks": "所有曲目", "roots": "音乐文件夹", "images": "光盘镜像", "lyrics": "歌词工作室", "output": "输出与均衡器", "lan": "iOS 连接", "appearance": "外观与语言", "database": "曲库管理"][model.page] ?? "音乐库"
    }
    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(title)).font(.system(size: 28, weight: .semibold))
                    Text(model.scanning ? L(model.scanMessage) : String(format:L("%d 个目录 · %d 个可用文件"),model.roots.count,model.availableFileCount))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if ["albums", "artists", "tracks"].contains(model.page) {
                    HStack { Image(systemName: "magnifyingglass"); TextField(L("搜索音乐库"), text: $model.search).textFieldStyle(.plain) }
                        .padding(9).frame(width: 220).negiGlass(10)
                }
                Button { model.importFolder() } label: { Label(L("导入文件夹"), systemImage: "plus") }.disabled(model.scanning)
                if model.scanning { Button(L("取消")) { model.cancelScan() } }
            }
            if !model.notice.isEmpty {
                HStack { Text(L(model.notice)).font(.caption).foregroundStyle(accent); Spacer(); Button { model.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            }
            if ["albums", "artists", "tracks"].contains(model.page), !model.files.isEmpty {
                HStack(spacing: 8) {
                    Picker(L("格式"), selection: $model.codecFilter) {
                        Text(L("全部格式")).tag("")
                        ForEach(model.codecChoices, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 160)
                    Picker(L("采样率"), selection: $model.rateFilter) {
                        ForEach(SourceRateFilter.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                    }.frame(width: 170)
                    Picker(L("状态"), selection: $model.availabilityFilter) {
                        ForEach(AvailabilityFilter.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                    }.frame(width: 140)
                    Spacer()
                    Text(String(format:L("%d 首"),model.filtered.count)).foregroundStyle(.secondary)
                    if !model.browseQuery.isDefault { Button(L("重置")) { model.resetBrowse() } }
                }.font(.caption)
                if model.page == "tracks" || model.selectedAlbum != nil || model.selectedArtist != nil {
                    HStack(spacing: 12) {
                        Picker(L("排序"), selection: $model.trackSort) {
                            ForEach(TrackSort.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                        }.frame(width: 180)
                        Button(L(model.sortAscending ? "升序 ↑" : "降序 ↓")) { model.sortAscending.toggle() }
                        Spacer()
                    }.font(.caption)
                }
            }
        }.padding(24)
    }
    var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(systemName: "opticaldisc").font(.system(size: 70, weight: .ultraLight)).foregroundStyle(accent.opacity(0.7))
            Text(L("让收藏成为音乐库")).font(.title2.weight(.medium))
            Text(L("选择本地或已挂载的音乐文件夹。\n音乐仍留在原处，曲库与歌词草稿保存在本机。")).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(L("选择音乐文件夹…")) { model.importFolder() }.negiProminentButton().padding(.top, 8)
            Text(L("MP3 · WAV · FLAC · AAC / ALAC\nDSF / DFF 可识别，DSD 播放正在开发")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var albumsView: some View {
        Group {
            if model.musicFileCount == 0 { emptyLibrary }
            else if let key = model.selectedAlbum {
                VStack(alignment: .leading) {
                    Button { model.selectedAlbum = nil } label: { Label(L("返回专辑"), systemImage: "chevron.left") }.padding([.top, .leading], 20)
                    tracksView(model.filtered.filter { $0.releaseKey == key })
                }
            } else {
                let groups = model.albumGroups
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)], alignment: .leading, spacing: 26) {
                        ForEach(groups, id: \.first!.releaseKey) { group in
                            if let first = group.first {
                                Button { model.selectedAlbum = first.releaseKey } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        ArtworkView(model: model, media: first, cornerRadius: 10)
                                        Text(uiAlbum(first)).font(.headline).lineLimit(1)
                                        Text(first.albumArtist.isEmpty ? uiArtist(first) : first.albumArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(LF("%d 首 · %@",group.count,Set(group.map(\.codec)).sorted().joined(separator:" / "))).font(.caption2).foregroundStyle(accent.opacity(0.8)).lineLimit(1)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(24)
                }
            }
        }
    }
    var artistsView: some View {
        Group {
            if model.musicFileCount == 0 { emptyLibrary }
            else if let artist = model.selectedArtist {
                VStack(alignment: .leading) {
                    Button { model.selectedArtist = nil } label: { Label(L("返回艺人"), systemImage: "chevron.left") }.padding([.top, .leading], 20)
                    tracksView(model.filtered.filter { $0.artists.contains(artist) })
                }
            } else {
                let artists = model.artistNames
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 24) {
                        ForEach(artists, id: \.self) { artist in
                            Button { model.selectedArtist = artist } label: {
                                VStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle").font(.system(size: 80, weight: .ultraLight)).foregroundStyle(accent.opacity(0.6))
                                    Text(artist).font(.headline)
                                    Text(String(format:L("%d 首曲目"),model.artistCounts[artist] ?? 0)).font(.caption).foregroundStyle(.secondary)
                                }.frame(height: 180)
                            }.buttonStyle(.plain)
                        }
                    }.padding(24)
                    if artists.isEmpty { Text(L("文件没有可读取的艺人标签。可在曲目页查看并播放。")).foregroundStyle(.secondary).padding(40) }
                }
            }
        }
    }
    func tracksView(_ files: [MediaFile]) -> some View {
        Group {
            if model.musicFileCount == 0 { emptyLibrary }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack { Text(L("曲目 / 艺人")); Spacer(); Text(L("格式")).frame(width: 140); Text(L("时长")).frame(width: 60) }
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
                        ForEach(files) { f in
                            HStack(spacing: 14) {
                                Button { model.play(f) } label: { Image(systemName: playback.current?.id == f.id && playback.isPlaying ? "waveform" : "play.fill").foregroundStyle(accent) }.buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(f.title).font(.system(size: 14, weight: .medium)).foregroundStyle(f.available ? Color.primary : .gray)
                                    Text("\(uiArtist(f)) · \(uiAlbum(f))").font(.caption).foregroundStyle(.secondary)
                                    if let issue = f.issue { Text(L(issue)).font(.caption2).foregroundStyle(.orange) }
                                    if !f.available { Text(L("文件离线或需要重新授权")).font(.caption2).foregroundStyle(.orange) }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 4) { Text(f.codec); Text(f.sampleRate > 0 ? String(format:"%.1f kHz",f.sampleRate/1000) : L("未探测")).foregroundStyle(.secondary) }.font(.caption).frame(width: 140, alignment: .trailing)
                                Text(durationText(f.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60)
                            }.padding(16).background(playback.current?.id == f.id ? accent.opacity(0.06) : .clear)
                                .contentShape(Rectangle()).onTapGesture(count: 2) { model.play(f) }
                                .contextMenu {
                                    Button(L("播放")) { model.play(f) }
                                    Button(L("下一首播放")) { model.enqueue(f, next: true) }.disabled(playback.current?.id == f.id)
                                    Button(L("加入队列")) { model.enqueue(f, next: false) }
                                    Divider()
                                    Button(L("查看所属专辑")) { model.resetBrowse(); model.selectedAlbum = f.releaseKey; model.page = "albums" }
                                    if !f.artists.isEmpty {
                                        Menu(L("查看艺人")) {
                                            ForEach(Array(Set(f.artists)).sorted(), id: \.self) { artist in
                                                Button(artist) { model.resetBrowse(); model.selectedArtist = artist; model.page = "artists" }
                                            }
                                        }
                                    }
                                    Button(L("在 Finder 中显示")) { model.reveal(f) }
                                }
                            Divider().padding(.leading, 48)
                        }
                        if files.isEmpty { Text(L("没有符合条件的曲目")).foregroundStyle(.secondary).padding(50) }
                    }
                }
            }
        }
    }
    var rootsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("引用文件夹")).font(.title2)
                Text(L("只读引用原目录，不复制音乐、不写回标签。索引与歌词草稿保存在本机；授权失效或磁盘离线时仍保留。")).foregroundStyle(.secondary)
                ForEach(model.roots) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 6) { Text(URL(fileURLWithPath: root.path).lastPathComponent).font(.headline); Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Text(L(root.status)).font(.caption).foregroundStyle(root.status == "在线" ? accent : .orange) }
                        Spacer(); Button(L("重新授权…")) { model.importFolder(reauthorizing: root.id) }.disabled(model.scanning)
                    }.padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                Button(L("重新扫描全部目录")) { model.rescan() }.disabled(model.scanning || model.roots.isEmpty)
                Text(L("歌词导出和数据库备份需选择音乐目录以外的位置。")).font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    var discImagesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("只读识别 SACD／ISO 9660 头部，镜像独立收录。SACD 曲目解析与 DST／DSD 解码尚未接通，当前不能播放镜像。CD-DA 通常需要 BIN／CUE 轨道信息。")).foregroundStyle(.secondary)
                if model.discImages.isEmpty {
                    ContentUnavailableView(L("尚无光盘镜像"), systemImage: "opticaldisc", description: Text(L("重新扫描已引用目录即可收录 ISO 文件")))
                }
                ForEach(model.discImages) { image in
                    HStack(spacing: 18) {
                        Image(systemName: "opticaldisc").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(image.title).font(.headline)
                            Text("\(image.codec) · \(ByteCountFormatter.string(fromByteCount: image.size, countStyle: .file))").font(.caption).foregroundStyle(accent)
                            Text(L(image.issue ?? "镜像播放尚未接通")).font(.caption).foregroundStyle(.secondary)
                            if !image.available { Text(L("磁盘离线或需要重新授权")).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button(L("在 Finder 中显示")) { model.reveal(image) }.disabled(!image.available)
                    }.padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                Button(L("重新扫描目录")) { model.rescan() }.disabled(model.scanning || model.roots.isEmpty)
            }.padding(28)
        }
    }
    var databaseView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L("本机 SQLite 曲库"), systemImage: "externaldrive").font(.title2)
            Text(model.databaseURL.path).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Button(L("检查完整性")) { model.checkDatabase() }; Button(L("导出一致备份…")) { model.backupDatabase() }; Button(L("重新扫描")) { model.rescan() }.disabled(model.scanning) }
            Text(L("采用 SQLite Online Backup API，备份覆盖 WAL 中已提交的数据。数据库备份不包含音乐文件。\n\n独立库切换、恢复向导、播放列表与标签写回正在开发。")).foregroundStyle(.secondary)
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
    var outputView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("实际播放链路")).font(.title2)
                Text(audioPath(playback)).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                Text(L("PCM 兼容模式使用系统音频图与软件音量。尚未完成独占／逐比特验证，DSD DoP 不会发送到任何设备。")).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) { Text(L("设备回读")).font(.headline); Text(L(playback.confirmedOutputFormat)).font(.caption) }
                    Spacer()
                    Text(LF("输出呈现延迟 %.1f ms",playback.latency*1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Divider()
                Text(L("响度与数字余量")).font(.title2)
                Picker(L("响度统一"), selection: $playback.loudnessMode) {
                    ForEach(LoudnessMode.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                Text(L(playback.loudness.status)).font(.callout).foregroundStyle(accent)
                HStack { Text(L("响度前级")); Slider(value: $playback.loudnessPreampDB, in: -12...12).frame(width: 240); Text("\(playback.loudnessPreampDB, specifier: "%+.1f") dB").monospacedDigit() }.disabled(playback.loudnessMode == .off)
                HStack { Text(L("数字余量")); Slider(value: $playback.headroomDB, in: 0...24, step: 0.5).frame(width: 240); Text("−\(playback.headroomDB, specifier: "%.1f") dB").monospacedDigit() }
                Toggle(L("按 ReplayGain 峰值标签限制增益"), isOn: $playback.preventPeakOverload)
                Text(L("读取已有 ReplayGain 标签，不修改音乐。专辑标签缺失时使用逐曲标签；没有有效标签时保留原响度。峰值标签不等于实时 true-peak 测量。")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(L("实际预增益")); Text(String(format: "%+.2f dB", abs(playback.loudness.gainDB) < 0.0001 ? 0 : playback.loudness.gainDB)).font(.callout.monospacedDigit()).foregroundStyle(accent) }
                Divider()
                Text(L("聆听偏好")).font(.title2)
                HStack { Text(L("软件音量上限")); Slider(value: $playback.volumeLimit, in: 0...1, step: 0.01).frame(width: 240); Text("\(Int((playback.volumeLimit * 100).rounded()))%").monospacedDigit() }
                Toggle(L("macOS 正在播放与媒体键"), isOn: $playback.mediaControls)
                Text(L("音量上限、响度、EQ 和所选设备保存在本机。恢复设备按 UID 匹配；设备离线时暂停，等待重新选择。")).font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack { Text(L("输出设备")).font(.headline); Spacer(); Button(L("刷新")) { playback.refreshDevices() } }
                Toggle(L("跟随歌曲源采样率（下次载入生效）"), isOn: $playback.followSourceSampleRate).disabled(playback.preparingOutput)
                Text(L(playback.sampleRateStatus)).font(.callout).foregroundStyle(accent)
                Text(L("切换前停止输出，确认设备采样率后恢复。此设置会改变所选设备的系统格式；不支持时保留当前格式并转换。仅匹配采样率不代表独占或逐比特输出。")).font(.caption).foregroundStyle(.secondary)
                ForEach(playback.devices) { device in
                    HStack {
                        Image(systemName: device.isUSB ? "cable.connector" : "hifispeaker").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing:4) {
                            Text(device.name+(device.isUSB ? " · USB" : ""))
                            Text(LF("当前设备格式 %d Hz · %@",Int(device.sampleRate),L(device.volumeWritable ? "公开可写音量属性，尚未验证控制" : "固定输出或未提供主音量"))).font(.caption).foregroundStyle(.secondary)
                            if !device.rateDescription.isEmpty { Text(L("支持的 PCM 采样率：")+device.rateDescription+" Hz").font(.caption).foregroundStyle(.secondary) }
                            if !device.physicalFormat.isEmpty { Text(L("驱动回报格式：")+device.physicalFormat).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(L(playback.actualDeviceID == device.id ? "已选择" : "选择并暂停")) { do { try playback.chooseDevice(device.id) } catch { model.error = error.localizedDescription } }.disabled(playback.preparingOutput)
                    }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                HStack {
                    Text(L("10 段均衡器")).font(.title2)
                    Spacer()
                    Toggle(L("启用 EQ"), isOn: Binding(get: { playback.eqEnabled }, set: { v in do { try playback.setEQ(v) } catch { model.error = error.localizedDescription } }))
                }
                Text(L("EQ 仅处理 PCM；关闭时绕过 EQ 节点。软件音量仍属于兼容播放链路。")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(L("前级增益")); Slider(value: $playback.preamp, in: -24...0).frame(width: 240); Text("\(playback.preamp, specifier: "%.1f") dB").monospacedDigit() }
                HStack(spacing: 10) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 10) {
                            Text("\(playback.gains[i], specifier: "%.0f") dB").font(.caption2).monospacedDigit()
                            Slider(value: Binding(get: { playback.gains[i] }, set: { playback.setGain($0, band: i) }), in: -12...12)
                            Text(playback.frequencies[i] >= 1000 ? "\(Int(playback.frequencies[i]/1000))k" : "\(Int(playback.frequencies[i]))").font(.caption)
                        }
                    }
                }.padding(.vertical, 12).disabled(!playback.eqEnabled)
                HStack {
                    Menu(L("EQ 预设：")+L(playback.presetName)) { ForEach(EQPreset.builtIn) { preset in Button(L(preset.name)) { playback.applyPreset(preset) } } }
                    Text(L("手动调整后标记为自定义")).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("预设是轻度音色调整，不是耳机测量校正。EQ 可旁路比较；实时削波计量和 DAC 硬件音量后续接入。")).font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    var queueView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(LF("播放队列 · %d",playback.queue.count)).font(.headline); Spacer(); Button { model.showQueue = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Button(L("清除待播曲目")) { playback.clearUpcoming() }.disabled(playback.queue.isEmpty)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(playback.queue) { f in
                        HStack(alignment: .top) {
                            Button { model.play(f, replaceQueue: false) } label: {
                                VStack(alignment: .leading, spacing: 4) { Text(f.title).foregroundStyle(playback.current?.id == f.id ? accent : Color.primary); Text(uiArtist(f)).font(.caption).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                            Spacer()
                            Menu {
                                Button(L("上移")) { playback.moveQueued(f.id, by: -1) }
                                Button(L("下移")) { playback.moveQueued(f.id, by: 1) }
                                Button(L("移除")) { playback.removeQueued(f.id) }.disabled(playback.current?.id == f.id)
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                        }
                    }
                }
            }
        }.padding(20)
    }
    var playerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 24) {
                Button { model.page = "playing" } label: { HStack(spacing: 12) {
                    ArtworkView(model: model, media: playback.current, cornerRadius: 6).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) { Text(playback.current?.title ?? L("未选择曲目")).font(.headline).lineLimit(1); Text(playback.current.map(uiArtist) ?? L("你的音乐，留在本机")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(width: 250, alignment: .leading) }.buttonStyle(.plain).accessibilityLabel(L("展开正在播放"))
                Button { playback.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(playback.shuffle ? accent : .secondary) }.buttonStyle(.plain)
                Button { model.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36)).foregroundStyle(accent) }.buttonStyle(.plain).disabled(playback.current == nil)
                Button { playback.advance() } label: { Image(systemName: "forward.end.fill") }.buttonStyle(.plain)
                Button { playback.repeatQueue.toggle() } label: { Image(systemName: "repeat").foregroundStyle(playback.repeatQueue ? accent : .secondary) }.buttonStyle(.plain)
                Text(durationText(playback.position)).font(.caption.monospacedDigit()).frame(width: 48)
                Slider(value: Binding(get: { playback.position }, set: { model.seek($0) }), in: 0...max(1,playback.duration)).disabled(playback.current == nil)
                Text(durationText(playback.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48)
                Button { playback.isMuted.toggle() } label: { Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.buttonStyle(.plain).accessibilityLabel(L(playback.isMuted ? "取消静音" : "静音"))
                VStack(spacing: 3) { Text(L("软件音量")).font(.caption2).foregroundStyle(.secondary); Slider(value: $playback.volume, in: 0...max(0.001,playback.volumeLimit)).frame(width: 90) }
                Button { model.showQueue.toggle() } label: { Image(systemName: "list.bullet") }.buttonStyle(.plain)
            }
            HStack { Text(audioPath(playback)).lineLimit(1); Spacer(); Text(L(playback.status)) }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 16).negiGlass(22).padding(.horizontal, 12).padding(.bottom, 12)
    }
}
