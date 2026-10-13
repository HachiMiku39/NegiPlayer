import SwiftUI
import LANCore
import AppKit
import LibraryDomain
import AudioCore

struct DesktopLANView:View {
    @ObservedObject var model:DesktopLANModel
    var onPlay:()->Void
    @State private var address=""
    @State private var fingerprint=""
    @State private var code=""
    @State private var confirmed=false
    var body:some View {
        VStack(spacing:16) {
            HStack {
                VStack(alignment:.leading) { Text(L("局域网播放")).font(.title2.bold()); Text(model.connected ? model.hostName : L("连接音乐主机")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.connected {
                    Button(L("刷新")) { Task { do { try await model.refresh() } catch { model.error=error.localizedDescription } } }
                    Button(L("断开并撤销配对")) { Task { await model.disconnect() } }
                }
            }.padding(.horizontal,24).padding(.top,20)
            if model.connected { DesktopLANConnectedView(model:model,player:model.player) }
            else {
                Form {
                    Section(L("连接与配对")) {
                        Text(L("连接 macOS 或 Windows 曲库主机，文件由主机管理，此 Mac 只读播放。"))
                        TextField("https://192.168.1.10:40439",text:$address)
                        TextField(L("证书 SHA-256 指纹"),text:$fingerprint).font(.system(.caption,design:.monospaced))
                        Toggle(L("已核对主机完整证书指纹"),isOn:$confirmed)
                        TextField(L("8 位配对码"),text:$code)
                        Button(L("配对并连接")) { Task { await model.pair(address:address,fingerprint:fingerprint,code:code,confirmed:confirmed) } }
                            .disabled(model.loading || !confirmed || code.count != 8 || !NegiLAN.validFingerprint(fingerprint.lowercased()))
                    }
                }.formStyle(.grouped)
            }
        }
        .onAppear { model.onPlay=onPlay }
        .task { await model.restore() }
        .onChange(of:address) { _ in confirmed=false }.onChange(of:fingerprint) { _ in confirmed=false }
        .alert(L("操作未完成"),isPresented:Binding(get:{model.error != nil || model.player.error != nil},set:{ if !$0 { model.error=nil; model.player.error=nil } })) {
            Button(L("知道了")) { model.error=nil; model.player.error=nil }
        } message: { Text(model.error ?? model.player.error ?? "") }
    }
}

private struct DesktopLANConnectedView:View {
    @ObservedObject var model:DesktopLANModel
    @ObservedObject var player:DesktopLANPlayer
    @State private var tab=0
    var body:some View {
        VStack(spacing:12) {
            Picker(L("音乐库"),selection:$tab) {
                Text(L("专辑")).tag(0); Text(L("所有曲目")).tag(1); Text(L("正在播放")).tag(2); Text(L("输出与均衡器")).tag(3)
            }.pickerStyle(.segmented).padding(.horizontal,24)
            Group {
                switch tab {
                case 2: DesktopLANNowPlaying(model:model,player:player)
                case 3: settings
                case 1: tracks
                default: albums
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.onChange(of:player.track?.id) { _ in if player.track != nil { tab=2 } }
    }
    var albums:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:0) {
                ForEach(model.albums) { album in
                    Button { model.select(album); tab=1 } label: {
                        HStack(spacing:14) {
                            DesktopLANAlbumCover(model:model,id:album.coverTrackID)
                            VStack(alignment:.leading,spacing:5) { Text(album.title.isEmpty ? L("未标记专辑") : album.title).font(.headline).lineLimit(2); Text(album.artist.isEmpty ? L("未知艺人") : album.artist).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(String(format:L("%d 首曲目"),album.count)).font(.caption).foregroundStyle(.secondary); Image(systemName:"chevron.right")
                        }.padding(.vertical,12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider().padding(.leading,66)
                }
            }.padding(.horizontal,24)
        }
    }
    var tracks:some View {
        VStack {
            HStack {
                if model.selectedAlbum != nil { Button(L("返回专辑")) { model.select(nil); tab=0 } }
                TextField(L("搜索音乐库"),text:$model.query).textFieldStyle(.roundedBorder)
            }.padding(.horizontal,24).onChange(of:model.query) { _ in model.queryChanged() }
            ScrollView { LazyVStack(alignment:.leading,spacing:0) {
                ForEach(model.tracks) { track in
                    Button { model.play(track) } label: {
                        HStack { Image(systemName:"play.fill"); VStack(alignment:.leading,spacing:5) { Text(track.title).font(.headline); Text(track.artist.isEmpty ? L("未知艺人") : track.artist).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(track.codec).font(.caption); Text(durationText(track.duration)).font(.caption.monospacedDigit()) }.padding(.vertical,12).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!track.playable); Divider()
                }
                if model.tracks.count<model.total { Button(L("加载更多")) { Task { await model.more() } }.disabled(model.loading) }
            }.padding(.horizontal,24) }
        }
    }
    var settings:some View {
        Form {
            Section(L("输出设备")) {
                Picker(L("输出设备"),selection:Binding(get:{player.preferences.preferredDeviceUID ?? ""},set:{player.selectOutput($0.isEmpty ? nil : $0)})) {
                    Text(L("系统默认输出")).tag("")
                    ForEach(player.devices) { device in Text(device.name).tag(device.uid) }
                }
                Text(player.signalPath).font(.caption)
                Text(L("采样率转换由系统处理，不宣称独占或逐比特输出")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("10 段均衡器")) {
                Toggle(L("启用 EQ"),isOn:$player.preferences.eqEnabled)
                ForEach(0..<10,id:\.self) { i in HStack {
                    Text(["32","64","125","250","500","1k","2k","4k","8k","16k"][i]).frame(width:34)
                    Slider(value:Binding(get:{Double(player.preferences.gains[i])},set:{player.preferences.gains[i]=Float($0)}),in:-12...12)
                    Text(String(format:"%+.1f dB",player.preferences.gains[i])).font(.caption.monospacedDigit()).frame(width:70)
                } }
                HStack { Text(L("前级增益")); Slider(value:Binding(get:{Double(player.preferences.eqPreampDB)},set:{player.preferences.eqPreampDB=Float($0)}),in:-24...0) }
            }
            Section(L("响度统一")) {
                Picker(L("响度统一"),selection:$player.preferences.loudnessMode) {
                    Text(L("关闭")).tag(LoudnessMode.off); Text(L("逐曲响度")).tag(LoudnessMode.track); Text(L("专辑响度")).tag(LoudnessMode.album)
                }
                HStack { Text(L("数字余量")); Slider(value:Binding(get:{Double(player.preferences.headroomDB)},set:{player.preferences.headroomDB=Float($0)}),in:0...24) }
                Toggle(L("按 ReplayGain 峰值标签限制增益"),isOn:$player.preferences.preventPeakOverload)
            }
        }.formStyle(.grouped)
    }
}

private struct DesktopLANAlbumCover:View {
    let model:DesktopLANModel
    let id:String
    @State private var image:NSImage?
    var body:some View {
        Group { if let image { Image(nsImage:image).resizable().scaledToFill() } else { Image(systemName:"opticaldisc").font(.title2) } }
            .frame(width:52,height:52).background(.quaternary).clipShape(RoundedRectangle(cornerRadius:8))
            .task(id:id) { image=await model.artwork(id) }
    }
}

private struct DesktopLANNowPlaying:View {
    @ObservedObject var model:DesktopLANModel
    @ObservedObject var player:DesktopLANPlayer
    @State private var following=true
    @State private var scrubbing=false
    @State private var scrub=0.0
    var active:Int? { model.lyrics.last(where:{($0.time ?? .infinity)<=player.position})?.id }
    var body:some View {
        GeometryReader { geometry in
            if player.track == nil { ContentUnavailableView(L("未选择曲目"),systemImage:"music.note") }
            else {
                HStack(spacing:40) {
                    Spacer(minLength:0)
                    VStack(spacing:18) {
                        Group { if let cover=model.cover { Image(nsImage:cover).resizable().scaledToFit() } else { Image(systemName:"opticaldisc").resizable().scaledToFit().padding(50).foregroundStyle(.secondary) } }
                            .frame(width:max(120,min(model.lyrics.isEmpty ? 460 : geometry.size.width*0.4,geometry.size.height-290)),height:max(120,min(model.lyrics.isEmpty ? 460 : geometry.size.width*0.4,geometry.size.height-290)))
                            .background(.quaternary,in:RoundedRectangle(cornerRadius:14)).clipShape(RoundedRectangle(cornerRadius:14))
                        Text(player.track?.title ?? "").font(.title2.bold()).lineLimit(2)
                        Text(player.track?.artist ?? "").foregroundStyle(.secondary)
                        Slider(value:Binding(get:{scrubbing ? scrub : player.position},set:{scrub=$0;if !scrubbing { player.seek($0) }}),in:0...max(0.01,player.duration),onEditingChanged:{editing in scrubbing=editing;if !editing { player.seek(scrub) }})
                        HStack { Text(durationText(player.position)); Spacer(); Text(durationText(player.duration)) }.font(.caption.monospacedDigit())
                        HStack(spacing:30) {
                            Button { model.next(-1) } label:{Image(systemName:"backward.end.fill")}
                            Button { player.toggle() } label:{Image(systemName:player.playing ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)}
                            Button { model.next(1) } label:{Image(systemName:"forward.end.fill")}
                        }.buttonStyle(.plain)
                        HStack { Text(L("软件音量")).font(.caption); Slider(value:Binding(get:{Double(player.preferences.volume)},set:{player.preferences.volume=Float($0)}),in:0...1) }
                        Text(player.signalPath).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }.frame(maxWidth:model.lyrics.isEmpty ? 500 : geometry.size.width*0.44)
                    if !model.lyrics.isEmpty {
                        ScrollViewReader { proxy in VStack(alignment:.leading) {
                            Button(L(following ? "自动跟随" : "恢复歌词跟随")) { following=true; if let active { withAnimation { proxy.scrollTo(active,anchor:.center) } } }.font(.caption)
                            ScrollView { LazyVStack(alignment:.leading,spacing:24) {
                                ForEach(model.lyrics) { line in Button { if let time=line.time { player.seek(time); following=true } } label:{Text(line.text).font(.system(size:26,weight:.semibold)).foregroundStyle(line.id==active ? Color.primary : Color.secondary.opacity(0.6)).multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)}.buttonStyle(.plain).id(line.id) }
                            }.padding(.vertical,geometry.size.height*0.35) }.simultaneousGesture(DragGesture().onChanged { _ in following=false })
                                .onChange(of:active) { id in if following,let id { withAnimation { proxy.scrollTo(id,anchor:.center) } } }
                        } }.frame(maxWidth:.infinity)
                    }
                    Spacer(minLength:0)
                }.padding(24)
            }
        }
    }
}
