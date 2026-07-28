import Foundation

enum URLCanonicalizer {
    /// Shorteners the supported sources hand out from their own share sheets. Each one is a
    /// bare redirect that carries no platform information, so it has to be expanded before a
    /// resolver can be chosen.
    private static let shortLinkHosts: Set<String> = [
        "instagr.am",
        "ig.me",
        "t.co",
        "vm.tiktok.com",
        "vt.tiktok.com",
        "m.tiktok.com",
        "pin.it",
        "youtu.be",
        "kick.com.br",
        "tmblr.co",
        "snapchat.com.link",
        "imgur.io"
    ]

    /// Query parameters that only identify who shared a link. Everything else is preserved,
    /// because a post identifier frequently lives in the query string.
    private static let trackingParameterPrefixes = ["utm_"]
    private static let trackingParameterNames: Set<String> = [
        "fbclid", "gclid", "igshid", "igsh", "si", "share_id", "_nc_cat",
        "ref_src", "ref_url", "s", "t", "share_app_id", "sender_device", "feature"
    ]

    static func canonicalize(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw ResolverError.invalidURL
        }
        components.scheme = "https"
        components.host = normalizedHost(host)
        components.fragment = nil
        components.queryItems = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            if trackingParameterPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            // A YouTube watch link and a Kick clip link both put the post identifier in the
            // query string, so a short parameter is only dropped when it is not load-bearing.
            if trackingParameterNames.contains(name) { return !isLoadBearing(name: name, host: components.host ?? "") }
            return true
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        guard let canonical = components.url else { throw ResolverError.invalidURL }
        return canonical
    }

    private static func isLoadBearing(name: String, host: String) -> Bool {
        switch name {
        case "v": return host.contains("youtube")
        case "t": return host.contains("youtube")
        default: return false
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host
        for prefix in ["www.", "m.", "mobile."] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return value
    }

    static func platform(for url: URL) -> Platform? {
        guard let host = url.host?.lowercased() else { return nil }
        let normalized = normalizedHost(host)
        return Platform.allCases.first { platform in
            platform.hostnames.contains { normalized == $0 || normalized.hasSuffix(".\($0)") }
        }
    }

    private static let directMediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "avif", "bmp", "tiff",
        "mp4", "mov", "m4v", "webm", "mkv",
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "oga", "opus"
    ]

    static func isDirectMedia(_ url: URL) -> Bool {
        guard let platform = platform(for: url), platform != .directMedia else {
            return directMediaExtensions.contains(url.pathExtension.lowercased())
        }
        // A platform page that happens to end in a media extension is still a platform page
        // unless it is served from that platform's media host.
        let host = url.host?.lowercased() ?? ""
        let isMediaHost = host.hasPrefix("i.") || host.hasPrefix("v.") || host.hasPrefix("cdn.") || host.contains("cdn")
        return isMediaHost && directMediaExtensions.contains(url.pathExtension.lowercased())
    }

    /// Short links do not contain enough information to choose a platform resolver. Resolve
    /// only the well-known source-platform shorteners, and only after a user explicitly asks
    /// Stashy to catch the link.
    static func isPlatformShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let normalized = normalizedHost(host)
        if shortLinkHosts.contains(normalized) { return true }
        // A bare identifier on a platform's own short domain is still a short link.
        return normalized.hasSuffix(".app.link") || normalized.hasSuffix(".onelink.me")
    }
}
