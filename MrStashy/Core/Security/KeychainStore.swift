import Foundation
import Security

enum ResolverCredential: String, CaseIterable, Sendable {
    case imgurClientID
    case tumblrAPIKey
    case xBearerToken
    case pinterestAccessToken
    case instagramAccessToken
    case threadsAccessToken
    case tikTokAccessToken
}

enum KeychainStore {
    private static let resolverService = "com.tryvaultline.mrstashy.resolvers"

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

    /// Resolver credentials are device-local and are never persisted in settings, manifests,
    /// archives, diagnostics, or source control. They may only be supplied by the person who
    /// owns the associated developer account.
    static func saveResolverCredential(_ value: String, for credential: ResolverCredential) throws {
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw ResolverError.authenticationRequired }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: resolverService,
            kSecAttrAccount: credential.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query.merging([
            kSecValueData: Data(secret.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, replacement in replacement } as CFDictionary, nil)
        guard status == errSecSuccess else { throw ResolverError.authenticationRequired }
    }

    static func resolverCredential(for credential: ResolverCredential) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: resolverService,
            kSecAttrAccount: credential.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteResolverCredential(for credential: ResolverCredential) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: resolverService,
            kSecAttrAccount: credential.rawValue
        ] as CFDictionary)
    }
}
