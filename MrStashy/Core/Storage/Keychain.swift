import Foundation
import Security

/// Developer keys a person adds live only here: never in settings, manifests, exports or logs.
enum Keychain {
    private static let service = "com.tryvaultline.mrstashy.credentials"

    static func save(_ value: String, for credential: Credential) throws {
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw StashyError.invalidLink }
        if credential == .discordBotToken {
            // Only a bot token is acceptable: three dot-separated segments, optionally prefixed.
            let raw = secret.hasPrefix("Bot ") ? String(secret.dropFirst(4)) : secret
            guard raw.split(separator: ".").count == 3 else { throw StashyError.invalidLink }
        }
        delete(credential)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credential.rawValue,
            kSecValueData: Data(secret.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw StashyError.storage }
    }

    static func read(_ credential: Credential) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credential.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ credential: Credential) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: credential.rawValue] as CFDictionary)
    }

    static func has(_ credential: Credential) -> Bool { read(credential) != nil }
}
