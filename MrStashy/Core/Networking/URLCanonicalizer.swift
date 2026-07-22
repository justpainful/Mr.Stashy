import Foundation

enum URLCanonicalizer {
    private static let shortLinkHosts: Set<String> = [
        "instagr.am",
        "t.co",
        "vm.tiktok.com",
        "vt.tiktok.com"
    ]

    static func canonicalize(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw ResolverError.invalidURL
        }
        components.scheme = "https"
        components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        components.fragment = nil
        components.queryItems = components.queryItems?.filter { item in
            !item.name.lowercased().hasPrefix("utm_") && item.name.lowercased() != "fbclid"
        }
        guard let canonical = components.url else { throw ResolverError.invalidURL }
        return canonical
    }

    static func platform(for url: URL) -> Platform? {
        guard let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: "") else { return nil }
        return Platform.allCases.first { platform in
            platform.hostnames.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
    }

    static func isDirectMedia(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "gif", "webp", "mp4", "mov", "m4v", "mp3", "m4a", "wav"].contains(extensionName)
    }

    /// Short links do not contain enough information to choose a platform resolver. Resolve
    /// only the well-known source-platform shorteners, and only after a user explicitly asks
    /// Stashy to catch the link.
    static func isPlatformShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: "") else { return false }
        return shortLinkHosts.contains(host)
    }
}
