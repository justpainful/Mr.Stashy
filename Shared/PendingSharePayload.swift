import Foundation

struct PendingSharePayload: Codable, Hashable, Sendable {
    let url: URL
    let receivedAt: Date
}

enum PendingShareStore {
    static let appGroup = "group.com.tryvaultline.mrstashy"
    private static let key = "pending-share-payloads"

    static func enqueue(_ urls: [URL], defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        guard let defaults else { return }
        let existing = (try? JSONDecoder().decode([PendingSharePayload].self, from: defaults.data(forKey: key) ?? Data())) ?? []
        let additions = urls.map { PendingSharePayload(url: $0, receivedAt: .now) }
        let unique = Dictionary(grouping: existing + additions, by: { URLCanonicalForm.string($0.url) }).compactMap { $0.value.first }
        defaults.set(try? JSONEncoder().encode(unique), forKey: key)
    }

    static func consumePendingURLs(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> [URL] {
        guard let defaults, let data = defaults.data(forKey: key) else { return [] }
        defaults.removeObject(forKey: key)
        return ((try? JSONDecoder().decode([PendingSharePayload].self, from: data)) ?? []).map(\.url)
    }
}

enum URLCanonicalForm {
    static func string(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString.lowercased() ?? url.absoluteString.lowercased()
    }
}
