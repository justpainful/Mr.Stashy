import Foundation

enum URLCanonicalizer {
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
}
