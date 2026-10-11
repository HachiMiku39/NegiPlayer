import SwiftUI
import AppKit
import AudioCore
import LyricCore

/// Listening view uses the same PlaybackSession and clock as the mini player and lyric studio.
struct NowPlayingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: PlaybackSession
    @State private var followLyrics = true
    var body: some View {
        GeometryReader { geometry in
            let lyrics = model.displayLyrics
            VStack(spacing:0) {
                HStack {
                    Button { model.page = "albums" } label: { Label(L("音乐库"),systemImage:"chevron.down") }.buttonStyle(.plain)
                    Spacer()
                    Text(L("正在播放")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button(L("刷新封面与歌词")) { model.refreshListeningAssets() }
                        Button(L("打开歌词工作室")) { model.page = "lyrics" }
                        Button(L("输出与聆听设置")) { model.page = "output" }
                    } label: { Image(systemName:"ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().frame(width:28).accessibilityLabel(L("播放页选项"))
                    Button { model.showQueue.toggle() } label: { Image(systemName:"list.bullet") }.buttonStyle(.plain).accessibilityLabel(L("播放队列"))
                }.padding(.horizontal,28).padding(.top,24).padding(.bottom,12)
                if playback.current == nil {
                    ContentUnavailableView(L("尚未选择音乐"),systemImage:"music.note",description:Text(L("从音乐库选择曲目开始播放")))
                } else if let lyrics, geometry.size.width >= 680 {
                    HStack(spacing:42) {
                        coverAndControls(maxCover:min(geometry.size.height-265,400))
                            .frame(width:min(geometry.size.width*0.46,430))
                        lyricPane(lyrics).frame(maxWidth:.infinity,maxHeight:.infinity)
                    }.padding(.horizontal,36).padding(.vertical,12)
                } else if let lyrics {
                    ScrollView {
                        VStack(spacing:28) {
                            coverAndControls(maxCover:280)
                            lyricPane(lyrics).frame(height:360)
                        }.padding(28)
                    }
                } else {
                    Spacer(minLength:0)
                    coverAndControls(maxCover:min(geometry.size.width-120,geometry.size.height-290,460))
                        .frame(maxWidth:500).padding(.horizontal,36)
                    Spacer(minLength:0)
                }
                if playback.current != nil {
                    Text(audioPath(playback)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal,28).padding(.vertical,16)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private func coverAndControls(maxCover: CGFloat) -> some View {
        VStack(alignment:.leading,spacing:18) {
            ArtworkView(model:model,media:playback.current,cornerRadius:16)
                .frame(maxWidth:max(160,maxCover)).shadow(color:.black.opacity(0.32),radius:24,y:16)
                .frame(maxWidth:.infinity)
            VStack(alignment:.leading,spacing:6) {
                Text(playback.current?.title ?? "").font(.system(size:24,weight:.semibold)).lineLimit(2).textSelection(.enabled)
                Text(playback.current.map(uiArtist) ?? "").font(.title3).foregroundStyle(accent).lineLimit(1)
                Text(playback.current.map(uiAlbum) ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing:4) {
                Slider(value:Binding(get:{playback.position},set:{model.seek($0)}),in:0...max(1,playback.duration))
                HStack { Text(durationText(playback.position)); Spacer(); Text(L("−")+durationText(max(0,playback.duration-playback.position))) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing:28) {
                Button { playback.shuffle.toggle() } label: { Image(systemName:"shuffle").foregroundStyle(playback.shuffle ? accent : Color.primary.opacity(0.5)) }.accessibilityLabel(L("随机播放"))
                Spacer(minLength:0)
                Button { playback.previous() } label: { Image(systemName:"backward.end.fill").font(.title2) }.accessibilityLabel(L("上一首"))
                Button { model.toggle() } label: { Image(systemName:playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size:34,weight:.semibold)).frame(width:44,height:48) }.accessibilityLabel(L(playback.isPlaying ? "暂停" : "播放"))
                Button { playback.advance() } label: { Image(systemName:"forward.end.fill").font(.title2) }.accessibilityLabel(L("下一首"))
                Spacer(minLength:0)
                Button { playback.repeatQueue.toggle() } label: { Image(systemName:"repeat").foregroundStyle(playback.repeatQueue ? accent : Color.primary.opacity(0.5)) }.accessibilityLabel(L("循环队列"))
            }.buttonStyle(.plain)
            HStack(spacing:12) {
                Button { playback.isMuted.toggle() } label: { Image(systemName:playback.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill") }.buttonStyle(.plain).accessibilityLabel(L(playback.isMuted ? "取消静音" : "静音"))
                Slider(value:$playback.volume,in:0...max(0.001,playback.volumeLimit))
                Image(systemName:"speaker.wave.3.fill").foregroundStyle(.secondary)
            }
        }
    }
    private func lyricPane(_ document: LyricDocument) -> some View {
        let active = document.activeRow(at:playback.position)
        return VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(L("歌词")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(L(followLyrics ? "自动跟随" : "恢复跟随")) { followLyrics.toggle() }.font(.caption).buttonStyle(.plain).foregroundStyle(accent)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:24) {
                        Color.clear.frame(height:70)
                        ForEach(document.rows) { row in
                            Button {
                                if let time = row.start { model.seek(document.displayTime(time).seconds); followLyrics = true }
                            } label: {
                                Text(row.text.isEmpty ? "♪" : row.text)
                                    .font(.system(size:28,weight:.semibold))
                                    .foregroundStyle(active == row.id ? Color.primary : Color.primary.opacity(0.32))
                                    .frame(maxWidth:.infinity,alignment:.leading).multilineTextAlignment(.leading)
                                    .padding(.vertical,4)
                            }.buttonStyle(.plain).id(row.id).disabled(row.start == nil)
                        }
                        Color.clear.frame(height:140)
                    }.padding(.horizontal,4)
                }
                .modifier(LyricScrollFollow(follow:$followLyrics))
                .onChange(of:active) { _,new in
                    if followLyrics, let new { withAnimation(.easeInOut(duration:0.35)) { proxy.scrollTo(new,anchor:.center) } }
                }
                .onChange(of:followLyrics) { _,new in if new, let active { withAnimation { proxy.scrollTo(active,anchor:.center) } } }
                .onAppear { if let active { proxy.scrollTo(active,anchor:.center) } }
                .id(document.id)
            }
            Text(L(model.listeningLyricStatus)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct LyricScrollFollow: ViewModifier {
    @Binding var follow: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _,phase in
                if phase == .interacting || phase == .tracking { follow = false }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance:8).onChanged { _ in follow = false })
        }
    }
}
