import Foundation
import Security
import LANCore

public struct PairedDevice: Codable, Identifiable, Sendable {
    public var id:String; public var name:String; public var pairedAt:Date; public var lastSeen:Date
    public var tokenHash:String
}
public actor PairingStore {
    private let url:URL; private var devices:[PairedDevice]
    private var code:String?; private var deadline=Date.distantPast; private var attempts=0
    public init(url:URL) throws {
        self.url=url
        if FileManager.default.fileExists(atPath:url.path) {
            let data=try Data(contentsOf:url); guard data.count<100_000 else { throw LANError.message("配对数据损坏，已保留") }
            devices=try JSONDecoder().decode([PairedDevice].self,from:data)
        } else { devices=[] }
    }
    public func renew(now:Date=Date()) throws -> String {
        var value:UInt32=0; guard SecRandomCopyBytes(kSecRandomDefault,MemoryLayout.size(ofValue:value),&value)==errSecSuccess else { throw LANError.message("无法生成配对码") }
        let text=String(format:"%08u",value%100_000_000); code=text; deadline=now.addingTimeInterval(300); attempts=0; return text
    }
    public func currentCode(now:Date=Date()) -> String { now<deadline && attempts<10 ? (code ?? "") : "" }
    public func closePairing() { code=nil; deadline = .distantPast }
    public func pair(_ request:PairRequest,now:Date=Date()) throws -> String {
        guard let code, now<deadline, attempts<10 else { throw LANError.status(403) }
        attempts+=1
        guard request.code.count==8, request.code==code else { throw LANError.status(403) }
        guard devices.count<32 else { throw LANError.message("配对设备已达上限，请先撤销旧设备") }
        var bytes=Data(count:32); let status=bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!) }
        guard status==errSecSuccess else { throw LANError.status(500) }
        let token=bytes.base64EncodedString(), name=String(request.deviceName.filter { !$0.isNewline && !($0.asciiValue.map{$0<32} ?? false) }.prefix(80))
        let d=PairedDevice(id:UUID().uuidString,name:name.isEmpty ? "iOS 播放终端" : name,pairedAt:now,lastSeen:now,tokenHash:NegiLAN.fingerprint(Data(token.utf8)))
        let old=devices; devices.append(d)
        do { try save() } catch { devices=old; throw error }
        self.code=nil; deadline = .distantPast; return token
    }
    public func authorize(_ header:String?,now:Date=Date()) -> String? {
        guard let header, header.hasPrefix("Bearer "), header.count<=128 else { return nil }
        let digest=NegiLAN.fingerprint(Data(header.dropFirst(7).utf8))
        guard let i=devices.firstIndex(where:{$0.tokenHash==digest}) else { return nil }
        // Last-seen is deliberately transient: streaming does not continually rewrite pairings.
        devices[i].lastSeen=now; return devices[i].id
    }
    public func list() -> [PairedDevice] { devices }
    public func revoke(_ id:String) throws { let old=devices; devices.removeAll{$0.id==id}; do { try save() } catch { devices=old; throw error } }
    private func save() throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(devices).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
