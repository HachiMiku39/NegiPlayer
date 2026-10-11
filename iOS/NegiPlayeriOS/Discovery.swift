import Foundation
import Combine
#if canImport(LANCore)
import LANCore
#endif

struct DiscoveredMac:Identifiable { let id:String; let name:String; let url:URL; let fingerprint:String }
@MainActor final class MacDiscovery:NSObject,ObservableObject,@preconcurrency NetServiceBrowserDelegate,@preconcurrency NetServiceDelegate {
    @Published var servers:[DiscoveredMac]=[]
    @Published var status="点击搜索同一局域网中的 Mac"
    private let browser=NetServiceBrowser(); private var resolving:[NetService]=[]
    func start() { browser.stop(); resolving.removeAll(); servers=[]; browser.delegate=self; status="正在发现 Mac…"; browser.searchForServices(ofType:NegiLAN.serviceType,inDomain:"local.") }
    func netServiceBrowser(_ browser:NetServiceBrowser,didFind service:NetService,moreComing:Bool) { guard resolving.count<32 else { return }; resolving.append(service); service.delegate=self; service.resolve(withTimeout:10) }
    func netServiceDidResolveAddress(_ service:NetService) {
        guard let host=service.hostName, let bytes=service.txtRecordData() else { return }; let txt=NetService.dictionary(fromTXTRecord:bytes)
        guard let fp=txt["fp"].flatMap({String(data:$0,encoding:.utf8)}), NegiLAN.validFingerprint(fp), let id=txt["id"].flatMap({String(data:$0,encoding:.utf8)}), NegiLAN.validID(id), let url=try? NegiLAN.baseURL("https://\(host):\(service.port)") else { return }
        servers.removeAll{$0.id==id}; servers.append(.init(id:id,name:service.name,url:url,fingerprint:fp)); status=LF("找到 %d 台 Mac",servers.count)
    }
    func netServiceBrowser(_ browser:NetServiceBrowser,didRemove service:NetService,moreComing:Bool) { resolving.removeAll{$0===service}; servers.removeAll{$0.name==service.name} }
    func netServiceBrowser(_ browser:NetServiceBrowser,didNotSearch errorDict:[String:NSNumber]) { status="未能发现设备，请检查 iOS 设置中的局域网权限，或手动输入 Mac 地址" }
}
