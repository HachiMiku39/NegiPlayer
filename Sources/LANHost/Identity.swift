import Foundation
import Security
import LANCore

public struct LANIdentity {
    public let identity:SecIdentity; public let fingerprint:String; public let serverID:String
    public static func load(directory:URL) throws -> LANIdentity {
        guard #available(macOS 15,*) else { throw LANError.message("局域网服务需要 macOS 15 或更新版本") }
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=directory.appendingPathComponent("identity.p12"), idURL=directory.appendingPathComponent("server-id.txt")
        if !fm.fileExists(atPath:file.path) {
            let temp=directory.appendingPathComponent("generation-"+UUID().uuidString,isDirectory:true)
            try fm.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]); defer { try? fm.removeItem(at:temp) }
            func run(_ args:[String]) throws {
                let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/openssl"); process.arguments=args; process.currentDirectoryURL=temp
                process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
                try process.run(); process.waitUntilExit(); guard process.terminationStatus==0 else { throw LANError.message("本机 HTTPS 身份生成失败") }
            }
            try run(["req","-x509","-newkey","rsa:2048","-nodes","-days","3650","-subj","/CN=NegiPlayer LAN","-keyout","key.pem","-out","cert.pem"])
            try run(["pkcs12","-export","-inkey","key.pem","-in","cert.pem","-out","identity.p12","-passout","pass:NegiPlayer-LAN"])
            try Data(contentsOf:temp.appendingPathComponent("identity.p12")).write(to:file,options:.atomic)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        // Non-empty PKCS#12 compatibility password; private-key protection is the 0700 directory/0600 file, not this public constant.
        let data=try Data(contentsOf:file); guard data.count<100_000 else { throw LANError.message("HTTPS 身份损坏，已保留原文件") }
        var items:CFArray?
        let options=[kSecImportExportPassphrase as String:"NegiPlayer-LAN",kSecImportToMemoryOnly as String:true] as [String:Any]
        let importStatus=SecPKCS12Import(data as CFData,options as CFDictionary,&items)
        guard importStatus==errSecSuccess,
              let first=(items as? [[String:Any]])?.first, let item=first[kSecImportItemIdentity as String] else { throw LANError.message("无法载入本机 HTTPS 身份（\(importStatus)）") }
        let identity=item as! SecIdentity
        var cert:SecCertificate?; guard SecIdentityCopyCertificate(identity,&cert)==errSecSuccess, let cert else { throw LANError.message("HTTPS 证书缺失") }
        let serverID:String
        if fm.fileExists(atPath:idURL.path) { serverID=try String(contentsOf:idURL,encoding:.utf8); guard NegiLAN.validID(serverID) else { throw LANError.message("服务器标识损坏") } }
        else { serverID=UUID().uuidString; try Data(serverID.utf8).write(to:idURL,options:.atomic) }
        return .init(identity:identity,fingerprint:NegiLAN.fingerprint(SecCertificateCopyData(cert) as Data),serverID:serverID)
    }
}
