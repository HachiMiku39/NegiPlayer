import Foundation
import Security
#if canImport(LANCore)
import LANCore
#endif

enum ConnectionStore {
    private static var query:[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.NegiPlayer.iOS.LAN",kSecAttrAccount as String:"paired-Mac"] }
    static func load() throws -> LANCredentials? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne; var item:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&item); if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess, let data=item as? Data else { throw LANError.message("无法读取钥匙串中的配对信息") }; return try JSONDecoder().decode(LANCredentials.self,from:data)
    }
    static func save(_ credentials:LANCredentials) throws {
        let data=try JSONEncoder().encode(credentials), update=[kSecValueData as String:data] as [String:Any]
        let status=SecItemUpdate(query as CFDictionary,update as CFDictionary)
        if status==errSecItemNotFound { var q=query; q[kSecValueData as String]=data; q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else { throw LANError.message("配对成功，但保存到钥匙串失败") } }
        else if status != errSecSuccess { throw LANError.message("保存配对信息失败") }
    }
    static func remove() throws { let status=SecItemDelete(query as CFDictionary); guard status==errSecSuccess || status==errSecItemNotFound else { throw LANError.message("移除配对信息失败") } }
}
