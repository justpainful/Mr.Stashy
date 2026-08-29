import Foundation

/// Turns whatever a person pasted into a URL Stashy can work with.
enum LinkParser {
    static let mediaExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "mp4", "mov", "m4v", "webm", "mkv", "m4a", "mp3", "aac", "wav", "ogg", "flac"]

    /// Finds the first URL inside free text (a share sheet often hands over a caption plus link).
    static func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = normalize(trimmed) { return direct }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            if let url = match.url, let normalized = normalize(url.absoluteString) { return normalized }
        }
        return nil
    }

    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            guard text.contains(".") else { return nil }
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host, host.contains(".") else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        components.fragment = nil
        // Tracking parameters change nothing about the post and would make the same link look new.
        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || ["igsh", "igshid", "si", "feature", "ref_src", "ref_url", "s", "t", "_r", "rdt", "share_id", "is_from_webapp", "sender_device", "web_id", "xmt", "fbclid", "gclid", "mc_cid", "mc_eid"].contains(name))
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url
    }

    static func platform(for url: URL) -> Platform {
        guard let host = url.host?.lowercased() else { return .web }
        if isDirectMedia(url) { return .web }
        for platform in Platform.allCases where platform != .web {
            for suffix in platform.hosts where host == suffix || host.hasSuffix("." + suffix) {
                return platform
            }
        }
        return .web
    }

    /// A link that ends in a media extension and is not a platform page.
    static func isDirectMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard mediaExtensions.contains(ext) else { return false }
        guard let host = url.host?.lowercased() else { return false }
        // A platform's own media hosts are still files; its page hosts never carry extensions.
        let pageHosts = ["www.tiktok.com", "www.youtube.com", "www.instagram.com", "x.com", "twitter.com", "www.reddit.com"]
        return !pageHosts.contains(host)
    }

    /// Short links that must be expanded before the platform's page can be read.
    static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let shorteners = ["vm.tiktok.com", "vt.tiktok.com", "youtu.be", "t.co", "pin.it", "redd.it", "tmblr.co", "instagr.am", "ig.me", "reddit.app.link", "on.soundcloud.com"]
        if shorteners.contains(host) { return true }
        if host.hasSuffix("tiktok.com"), url.path.hasPrefix("/t/") { return true }
        if host.hasSuffix("reddit.com"), url.path.contains("/s/") { return true }
        if host.hasSuffix("snapchat.com"), url.path.hasPrefix("/t/") { return true }
        return false
    }

    static func pathComponents(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
