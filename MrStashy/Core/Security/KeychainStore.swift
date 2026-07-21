import Foundation
import Security

enum KeychainStore {
    static func saveDiscordBotToken(_ token: String) throws {
        guard token.hasPrefix("Bot ") || token.split(separator: ".").count == 3 else { throw ResolverError.authenticationRequired }
        let service = "com.tryvaultline.mrstashy.discord"
        let account = "bot-token"
        let data = Data(token.utf8)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw ResolverError.authenticationRequired }
    }

    static func deleteDiscordBotToken() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.tryvaultline.mrstashy.discord", kSecAttrAccount: "bot-token"] as CFDictionary)
    }
}
