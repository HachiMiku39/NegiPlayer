import SwiftUI
import AVKit
import MediaPlayer
#if canImport(LANCore)
import LANCore
#endif

struct MobileRoot:View {
    @ObservedObject var model:MobileModel
    @ObservedObject var audio:MobilePlayer
    @SceneStorage("selected-tab") private var tab=0
    @AppStorage("album-display-mode") private var albumDisplayMode="grid"
    @State private var fullscreen=false
    var body:some View {
        TabView(selection:$tab) {
            NavigationStack { library.safeAreaInset(edge:.bottom,spacing:0) { miniPlayer } }.tabItem { Label(L("专辑"),systemImage:"square.grid.2x2") }.tag(0)
            NavigationStack { trackList.safeAreaInset(edge:.bottom,spacing:0) { miniPlayer } }.tabItem { Label(L("所有曲目"),systemImage:"music.note.list") }.tag(1)
            NavigationStack {
                MobileNowPlaying(model:model,audio:audio,mv:model.mv).navigationTitle(L("正在播放")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button { fullscreen=true } label: { Image(systemName:"arrow.up.left.and.arrow.down.right") }.accessibilityLabel(L("全屏")) }
            }.tabItem { Label(L("正在播放"),systemImage:"play.square") }.tag(2)
            NavigationStack { MobileSettings(model:model,audio:audio,discovery:model.discovery).safeAreaInset(edge:.bottom,spacing:0) { miniPlayer } }.tabItem { Label(L("设置"),systemImage:"gearshape") }.tag(3)
        }
        .background(surface)
        .onChange(of:model.showPlayer) { _,value in if value { tab=2; model.showPlayer=false } }
        .alert(L("操作未完成"),isPresented:Binding(get:{model.error != nil || audio.error != nil},set:{if !$0 { model.error=nil; audio.error=nil }})) { Button(L("知道了"),role:.cancel) { model.error=nil; audio.error=nil } } message: { Text(L(model.error ?? audio.error ?? "")) }
        .fullScreenCover(isPresented:$fullscreen) { NavigationStack { MobileNowPlaying(model:model,audio:audio,mv:model.mv).toolbar { Button(L("完成")) { fullscreen=false } } }.tint(accent) }
    }
    @ViewBuilder var miniPlayer:some View {
            if let track=audio.track {
                HStack(spacing:12) {
                    if let image=model.artwork { Image(uiImage:image).resizable().scaledToFit().frame(width:42,height:42).clipShape(RoundedRectangle(cornerRadius:7)) }
                    Button { tab=2 } label: { VStack(alignment:.leading) { Text(track.title).font(.callout.bold()).lineLimit(1); Text(uiArtist(track)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                    if audio.buffering { ProgressView() }
                    Button { audio.toggle() } label: { Image(systemName:audio.playing ? "pause.fill" : "play.fill").font(.title2).frame(width:44,height:44) }.accessibilityLabel(L(audio.playing ? "暂停" : "播放"))
                    Button { model.next() } label: { Image(systemName:"forward.end.fill").frame(width:44,height:44) }
                }.padding(10).background(.regularMaterial)
            }
    }
    var library:some View {
        GeometryReader { g in
            if !model.connected { disconnected }
            else if g.size.width>=780, g.size.height>=360 {
                HStack(spacing:0) { albumBrowser.frame(width:g.size.width*0.45); Divider(); trackContent }
            } else { albumBrowser }
        }.navigationTitle(L("音乐库"))
        .toolbar { Button { Task { do { try await model.reloadAlbums() } catch { model.error=error.localizedDescription } } } label: { Image(systemName:"arrow.clockwise") }; Button { tab=3 } label: { Image(systemName:"network") } }
    }
    var disconnected:some View {
        ContentUnavailableView { Label(L("连接主机曲库"),systemImage:"desktopcomputer") } description: { Text(L("音乐由主机管理；此设备只读浏览，在本机处理音频。")) } actions: { Button(L("连接与配对")) { tab=3 } }
    }
    var albumBrowser:some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:12) {
                Text(LF("%d 张专辑",model.albums.count)).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                AlbumDisplayPicker(mode:$albumDisplayMode)
            }.padding(16)
            if model.albums.isEmpty {
                ContentUnavailableView(L("没有匹配的专辑"),systemImage:"square.stack",description:Text(L("从主机导入音乐后刷新曲库")))
            } else {
                ScrollView {
                    if albumDisplayMode == AlbumDisplayMode.list.rawValue {
                        LazyVStack(spacing:0) {
                            ForEach(model.albums) { album in
                                Button { model.select(album); tab=1 } label: {
                                    HStack(spacing:14) {
                                        RemoteArtwork(model:model,id:album.coverTrackID,cornerRadius:8).frame(width:60,height:60)
                                        VStack(alignment:.leading,spacing:5) {
                                            Text(album.title.isEmpty ? L("未标记专辑") : album.title).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                            Text(album.artist.isEmpty ? L("未知艺人") : album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                            Text(LF("%d 首曲目",album.count)).font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth:.infinity,alignment:.leading)
                                        Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }.padding(.vertical,12).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Divider().padding(.leading,74)
                            }
                        }.padding(.horizontal,16)
                    } else {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:140,maximum:240),spacing:20)],alignment:.leading,spacing:24) {
                            ForEach(model.albums) { album in
                                Button { model.select(album); tab=1 } label: {
                                    VStack(alignment:.leading,spacing:7) {
                                        RemoteArtwork(model:model,id:album.coverTrackID,cornerRadius:8).aspectRatio(1,contentMode:.fit)
                                            .shadow(color:.black.opacity(0.12),radius:8,y:3)
                                        Text(album.title.isEmpty ? L("未标记专辑") : album.title).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(height:40,alignment:.topLeading)
                                        Text(album.artist.isEmpty ? L("未知艺人") : album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        Text(LF("%d 首曲目",album.count)).font(.caption).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal,16).padding(.top,4)
                    }
                }.padding(.bottom,16)
            }
        }.background(surface)
    }
    var trackList:some View { trackContent.navigationTitle(L("所有曲目")) }
    var trackContent:some View {
        Group {
            if !model.connected { disconnected }
            else {
                List {
                    if let album=model.selectedAlbum { Button(L("返回专辑")) { model.select(nil) }; Text(album.title.isEmpty ? L("未标记专辑") : album.title).font(.headline) }
                    ForEach(model.tracks) { track in
                        Button { model.play(track) } label: {
                            HStack { Image(systemName:audio.track?.id==track.id ? "waveform" : "play.fill").foregroundStyle(accent); VStack(alignment:.leading,spacing:5) { Text(track.title).foregroundStyle(.primary).lineLimit(2); Text(uiArtist(track)+" · "+track.codec).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(timeText(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }.disabled(!track.playable).contextMenu { Button(L("加入队列")) { model.enqueue(track) } }
                    }
                    if model.tracks.count<model.total { Button(L("加载更多")) { Task { await model.moreTracks() } }.disabled(model.loading) }
                    if model.loading { ProgressView() }
                }.scrollContentBackground(.hidden).background(surface)
                .searchable(text:$model.query,prompt:L("搜索音乐库")).onChange(of:model.query){_,_ in model.queryChanged()}
            }
        }
    }
}
func uiArtist(_ track:RemoteTrack)->String { track.artist.isEmpty ? L("未知艺人") : track.artist }
func uiAlbum(_ track:RemoteTrack)->String { track.album.isEmpty ? L("未标记专辑") : track.album }

func timeText(_ seconds:Double)->String { guard seconds.isFinite,seconds>=0 else { return "—" }; return String(format:"%d:%02d",Int(seconds)/60,Int(seconds)%60) }
struct RemoteArtwork:View {
    @ObservedObject var model:MobileModel; let id:String
    var cornerRadius:CGFloat=14
    @State private var image:UIImage?
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:cornerRadius).fill(accent.opacity(0.1))
            if let image { Image(uiImage:image).resizable().scaledToFit() }
            else { GeometryReader { geometry in Image(systemName:"opticaldisc").resizable().scaledToFit().padding(min(geometry.size.width,geometry.size.height)*0.28).foregroundStyle(.secondary) } }
        }.clipShape(RoundedRectangle(cornerRadius:cornerRadius))
            .accessibilityLabel(L(image == nil ? "封面占位图" : "专辑封面"))
            .task(id:id) { image=nil; let loaded=await model.image(for:id); if !Task.isCancelled { image=loaded } }
    }
}
struct MobileNowPlaying:View {
    @ObservedObject var model:MobileModel; @ObservedObject var audio:MobilePlayer; @ObservedObject var mv:MutedMV
    @State private var follow=true
    @State private var showQueue=false
    @State private var scrubbing=false
    @State private var scrubPosition=0.0
    var active:Int? { model.lyrics.last(where:{($0.time ?? .infinity)<=audio.position})?.id }
    var body:some View {
        GeometryReader { geometry in
            if audio.track==nil { ContentUnavailableView(L("尚未选择音乐"),systemImage:"music.note") }
            else if mv.enabled && !mv.failed { stage }
            else {
                let split=MobileLayout.splitLyrics(width:geometry.size.width,height:geometry.size.height,hasLyrics:!model.lyrics.isEmpty)
                let cover=MobileLayout.coverLimit(width:geometry.size.width,height:geometry.size.height,split:split)
                Group {
                    if split { HStack(spacing:30) { ScrollView { controls(cover:cover) }.frame(maxWidth:.infinity); lyrics.frame(maxWidth:.infinity) }.padding(20) }
                    else { ScrollView { VStack(spacing:24) { controls(cover:cover); if !model.lyrics.isEmpty { lyrics.frame(minHeight:300) } }.padding(20).frame(maxWidth:560).frame(maxWidth:.infinity) } }
                }.background(surface)
            }
        }
        .toolbar {
            if mv.available { Button(mv.enabled || mv.preparing ? L("封面") : "MV") { mv.toggle(at:audio.position) } }
            Button { showQueue=true } label: { Image(systemName:"list.bullet") }.accessibilityLabel(L("播放队列"))
        }
        .overlay(alignment:.top) { if mv.failed { Text(L("MV 未能载入，继续显示封面与歌词")).font(.caption).padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)) } }
        .sheet(isPresented:$showQueue) { NavigationStack { List { ForEach(model.queue) { track in Button { model.play(track,replaceQueue:false); showQueue=false } label:{ VStack(alignment:.leading){Text(track.title);Text(uiArtist(track)).font(.caption).foregroundStyle(.secondary)} } } }.navigationTitle(L("播放队列")).toolbar { Button(L("完成")) { showQueue=false } } } }
    }
    func controls(cover:Double)->some View {
        VStack(alignment:.leading,spacing:16) {
            Group { if let image=model.artwork { Image(uiImage:image).resizable().scaledToFit() } else { Image(systemName:"opticaldisc").resizable().scaledToFit().padding(cover*0.25).foregroundStyle(.secondary).background(accent.opacity(0.08)) } }
                .frame(width:cover,height:cover).clipShape(RoundedRectangle(cornerRadius:18)).shadow(color:.black.opacity(0.16),radius:16,y:8).frame(maxWidth:.infinity)
            Text(audio.track?.title ?? "").font(.title2.bold()).lineLimit(2)
            Text(audio.track.map(uiArtist) ?? "").font(.title3).foregroundStyle(accent).lineLimit(1)
            Text(audio.track.map(uiAlbum) ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            playbackControls
            HStack { Text(L("软件音量")); Slider(value:Binding(get:{Double(audio.preferences.volume)},set:{audio.preferences.volume=Float($0)}),in:0...max(0.01,Double(audio.preferences.volumeLimit))); Button { audio.muted.toggle() } label: { Image(systemName:audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") } }.font(.caption)
            Text("\(Int(audio.track?.sampleRate ?? 0)) Hz PCM → iOS"+(audio.preferences.eqEnabled ? " EQ" : "")+" → \(audio.output) · \(Int(audio.outputRate)) Hz").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:520)
    }
    var playbackControls:some View {
        VStack(spacing:12) {
            Slider(value:Binding(get:{scrubbing ? scrubPosition : audio.position},set:{scrubPosition=$0; if !scrubbing { audio.seek($0) }}),in:0...max(0.01,audio.duration),onEditingChanged:{ editing in scrubbing=editing; if !editing { audio.seek(scrubPosition) } }).accessibilityLabel(L("播放位置"))
            HStack { Text(timeText(audio.position)); Spacer(); if audio.buffering { ProgressView().controlSize(.small) }; Text("−"+timeText(max(0,audio.duration-audio.position))) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button { model.shuffle.toggle() } label:{Image(systemName:"shuffle").foregroundStyle(model.shuffle ? accent : Color.secondary)}
                Spacer(); Button { model.previous() } label:{Image(systemName:"backward.end.fill")}
                Spacer(); Button { audio.toggle() } label:{Image(systemName:audio.playing ? "pause.fill" : "play.fill").font(.system(size:36)).frame(width:60,height:60)}
                Spacer(); Button { model.next() } label:{Image(systemName:"forward.end.fill")}
                Spacer(); Button { model.repeatQueue.toggle() } label:{Image(systemName:"repeat").foregroundStyle(model.repeatQueue ? accent : Color.secondary)}
            }.font(.title2).buttonStyle(.plain)
        }
    }
    var lyrics:some View {
        VStack {
            HStack { Text(L("歌词")).foregroundStyle(.secondary); Spacer(); Button(L(follow ? "自动跟随" : "恢复跟随")) { follow.toggle() }.font(.caption) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:28) {
                        Color.clear.frame(height:70)
                        ForEach(model.lyrics) { line in Button { if let time=line.time { follow=true; audio.seek(time) } } label: { Text(line.text).font(.system(size:28,weight:.bold)).foregroundStyle(active==line.id ? Color.primary : Color.primary.opacity(0.35)).frame(maxWidth:.infinity,alignment:.leading).multilineTextAlignment(.leading) }.buttonStyle(.plain).id(line.id) }
                        Color.clear.frame(height:100)
                    }.padding(.horizontal,8)
                }.modifier(MobileLyricFollow(follow:$follow))
                .onChange(of:active) { _,value in if follow, let value { withAnimation(.easeInOut(duration:0.35)) { proxy.scrollTo(value,anchor:.center) } } }
                .onChange(of:follow) { _,value in if value,let active { withAnimation { proxy.scrollTo(active,anchor:.center) } } }
            }
        }
    }
    var stage:some View {
        ZStack {
            Color.black.ignoresSafeArea(); MVSurface(player:mv.player)
            VStack { Spacer(); if let active,let line=model.lyrics.first(where:{$0.id==active}) { Text(line.text).font(.title.bold()).foregroundStyle(.white).multilineTextAlignment(.center).padding(12).background(.black.opacity(0.5),in:RoundedRectangle(cornerRadius:14)) }; playbackControls.padding(16).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:18)) }.padding(20)
        }.environment(\.colorScheme,.dark)
    }
}
private struct MobileLyricFollow:ViewModifier {
    @Binding var follow:Bool
    @ViewBuilder func body(content:Content)->some View { if #available(iOS 18,*) { content.onScrollPhaseChange { _,phase in if phase == .tracking || phase == .interacting { follow=false } } } else { content.simultaneousGesture(DragGesture(minimumDistance:5).onChanged{_ in follow=false}) } }
}
struct MobileSettings:View {
    @ObservedObject var model:MobileModel; @ObservedObject var audio:MobilePlayer; @ObservedObject var discovery:MacDiscovery
    @State private var address=""
    @State private var fingerprint=""
    @State private var code=""
    @State private var expectedID:String?
    @State private var confirmed=false
    var body:some View {
        Form {
            Section(L("外观与语言")) { AppearanceControls() }
            Section(L("连接与配对")) {
                if model.connected { Text(model.serverName); Text(L("曲库只读 · 文件管理在主机")); Button(L("断开并移除配对"),role:.destructive) { Task { await model.disconnect() } } }
                else {
                    Button(L("搜索音乐主机")) { discovery.start() }; Text(L(discovery.status)).font(.caption)
                    ForEach(discovery.servers) { server in Button(server.name) { address=server.url.absoluteString; fingerprint=server.fingerprint; expectedID=server.id; confirmed=false } }
                    TextField(L("主机 HTTPS 地址"),text:$address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField(L("证书 SHA-256 指纹"),text:$fingerprint,axis:.vertical).font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle(L("已与主机显示的完整指纹核对一致"),isOn:$confirmed)
                    TextField(L("8 位配对码"),text:$code).keyboardType(.numberPad)
                    Button(L("配对并连接")) { Task { await model.pair(url:address,fingerprint:fingerprint,code:code,expectedServerID:discovery.servers.first(where:{$0.url.absoluteString==address && $0.fingerprint==fingerprint})?.id) } }.disabled(!confirmed || code.count != 8 || !NegiLAN.validFingerprint(fingerprint.lowercased()) || model.loading)
                }
            }
            Section(L("输出设备")) {
                Text(audio.output); Text("\(Int(audio.outputRate)) Hz · \(audio.isUSB ? "USB" : L("系统音频路由"))").font(.caption)
                RoutePicker().frame(height:44)
                Picker(L("首选输出采样率"),selection:Binding(get:{audio.preferredRate},set:{audio.changePreferredRate($0)})) { Text(L("跟随源采样率")).tag(0.0); ForEach([44100.0,48000,88200,96000,176400,192000],id:\.self) { Text("\(Int($0)) Hz").tag($0) } }
                Text(L("USB 声卡由 iOS 系统路由，首选采样率仅是请求；上方显示实际输出。拔出音频设备会暂停。" )).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("10 段均衡器")) {
                Toggle(L("启用 EQ"),isOn:$audio.preferences.eqEnabled)
                Picker(L("预设"),selection:Binding(get:{audio.preferences.presetName},set:{ name in if let p=EQPreset.builtIn.first(where:{$0.name==name}) { audio.preferences.gains=p.gains; audio.preferences.eqPreampDB=p.preampDB; audio.preferences.presetName=name } })) { Text(L("自定义")).tag("自定义"); ForEach(EQPreset.builtIn) { Text(L($0.name)).tag($0.name) } }
                ForEach(0..<10,id:\.self) { i in HStack { Text(["32","64","125","250","500","1k","2k","4k","8k","16k"][i]).frame(width:36); Slider(value:Binding(get:{Double(audio.preferences.gains[i])},set:{audio.preferences.gains[i]=Float($0);audio.preferences.presetName="自定义"}),in:-12...12); Text(String(format:"%+.1f",audio.preferences.gains[i])).font(.caption.monospacedDigit()).frame(width:44) } }
                HStack { Text(L("前级增益")); Slider(value:Binding(get:{Double(audio.preferences.eqPreampDB)},set:{audio.preferences.eqPreampDB=Float($0)}),in:-24...0); Text(String(format:"%.1f dB",audio.preferences.eqPreampDB)).font(.caption) }
            }
            Section(L("响度与数字余量")) {
                Picker(L("响度统一"),selection:$audio.preferences.loudnessMode) { ForEach(LoudnessMode.allCases,id:\.self) { Text(L($0.rawValue)).tag($0) } }
                Toggle(L("按 ReplayGain 峰值标签限制增益"),isOn:$audio.preferences.preventPeakOverload)
                HStack { Text(L("数字余量")); Slider(value:Binding(get:{Double(audio.preferences.headroomDB)},set:{audio.preferences.headroomDB=Float($0)}),in:0...24); Text(String(format:"%.1f dB",audio.preferences.headroomDB)).font(.caption) }
                HStack { Text(L("软件音量上限")); Slider(value:Binding(get:{Double(audio.preferences.volumeLimit)},set:{audio.preferences.volumeLimit=Float($0);audio.preferences.volume=min(audio.preferences.volume,Float($0))}),in:0...1) }
                Text(L("EQ、增益及输出由 iOS 处理。播放链路会按系统与 USB 设备能力转换采样率，不声明 bit-perfect。" )).font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(L("设置"))
        .onChange(of:address) { _,_ in confirmed=false }
        .onChange(of:fingerprint) { _,_ in confirmed=false }
    }
}
struct RoutePicker:UIViewRepresentable {
    func makeUIView(context:Context)->AVRoutePickerView { let view=AVRoutePickerView(); view.prioritizesVideoDevices=false; return view }
    func updateUIView(_ view:AVRoutePickerView,context:Context) { view.tintColor=UIColor(accent); view.activeTintColor=UIColor(accent) }
}
