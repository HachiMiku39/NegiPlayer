import SwiftUI
import Combine
import LANHost
import LANCore
import MediaIO

@MainActor final class LANController: ObservableObject {
    @Published var state=LANHostState()
    @Published var error:String?
    @Published var busy=false
    let server:LANServer?
    init(directory:URL,artwork:ArtworkRepository) {
        do { server=try LANServer(directory:directory,artwork:artwork,name:(Host.current().localizedName ?? "Mac")+" · NegiPlayer") }
        catch { server=nil; self.error=error.localizedDescription }
    }
    func refresh() async { if let server { state=await server.snapshot() } }
    func toggle() {
        guard !busy, let server else { return }; busy=true
        Task {
            do { if state.running { await server.stop() } else { try await server.start() } }
            catch { self.error=error.localizedDescription }
            busy=false; await refresh()
        }
    }
    func newCode() { Task { do { _=try await server?.renewCode(); await refresh() } catch { self.error=error.localizedDescription } } }
    func revoke(_ id:String) { Task { do { try await server?.revoke(id); await refresh() } catch { self.error=error.localizedDescription } } }
    var address:String {
        let h=ProcessInfo.processInfo.hostName
        let host=h.hasSuffix(".local") ? h : h+".local"
        return "https://\(host):\(state.port)"
    }
}

struct LANConnectionView: View {
    @ObservedObject var host:LANController
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    VStack(alignment:.leading,spacing:6) {
                        Label(L("iOS 播放终端"),systemImage:"iphone.and.arrow.forward").font(.title2.bold())
                        Text(L(host.state.message)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L(host.state.running ? "关闭服务" : "开启局域网服务")) { host.toggle() }.disabled(host.busy || host.server==nil)
                }
                Text(L("Mac 管理文件和索引，只提供音频流、封面、LRC 与同名本地 MV。iOS 只读浏览曲库，在本机处理 EQ 与音频输出。Mac 的音量、EQ 和输出设备不会作用于 iOS 音频流。"))
                    .foregroundStyle(.secondary)
                if host.state.running {
                    VStack(alignment:.leading,spacing:12) { Text(L("连接与配对")).font(.headline)
                        VStack(alignment:.leading,spacing:12) {
                            Text(L("在 iPhone／iPad 的 NegiPlayer 中选择这台 Mac，或输入以下地址。两端需处于同一局域网。")).font(.callout)
                            Text(host.address).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                            Text(L("证书 SHA-256 指纹")).font(.caption).foregroundStyle(.secondary)
                            Text(host.state.fingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                            HStack {
                                Text(host.state.code.isEmpty ? L("未开放新设备配对") : host.state.code).font(.system(size:24,weight:.bold,design:.monospaced))
                                Spacer(); Button(L("生成 5 分钟配对码")) { host.newCode() }
                            }
                            Text(L("首次连接请核对完整指纹。配对码成功使用一次即关闭，10 次失败后锁定；重新生成可恢复。服务不会自动开启。")).font(.caption).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
                VStack(alignment:.leading,spacing:12) { Text(L("已配对设备")).font(.headline)
                    VStack(alignment:.leading,spacing:14) {
                        if host.state.devices.isEmpty { Text(L("尚无配对设备")).foregroundStyle(.secondary) }
                        ForEach(host.state.devices) { device in
                            HStack {
                                Image(systemName:"iphone").font(.title2)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(device.name).font(.headline)
                                    Text(L("最近连接：")+device.lastSeen.formatted()).font(.caption).foregroundStyle(.secondary)
                                    if let output=host.state.outputs[device.id] {
                                        Text("\(L(output.playing ? "播放中" : "已暂停")) · \(output.output) · \(Int(output.sampleRate)) Hz · EQ \(L(output.eqEnabled ? "开启" : "关闭"))").font(.caption)
                                        if !output.trackTitle.isEmpty { Text(output.trackTitle).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }; Spacer(); Button(L("撤销配对"),role:.destructive) { host.revoke(device.id) }
                            }; Divider()
                        }
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                }
                if let error=host.error { Text(L(error)).foregroundStyle(.pink) }
                Text(L("HTTPS 仅接受本地／私有网络连接。Mac 休眠、退出、外置盘离线或关闭服务会中断传输；iOS 不保存音乐副本或可写数据库。")).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.task { while !Task.isCancelled { await host.refresh(); do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { break } } }
    }
}
