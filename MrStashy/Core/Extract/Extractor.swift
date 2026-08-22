import Foundation

protocol Extractor: Sendable {
    var platform: Platform { get }
    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post
}

/// Where an extractor asks for a person's own developer key. Never a session cookie.
protocol CredentialSource: Sendable {
    func value(for credential: Credential) -> String?
}

enum Credential: String, CaseIterable, Codable, Sendable {
    case discordBotToken
    case xBearerToken
    case imgurClientID
    case tumblrAPIKey

    var titleKey: String { "credential.\(rawValue)" }
    var helpKey: String { "credential.\(rawValue).help" }
}

struct KeychainCredentials: CredentialSource {
    func value(for credential: Credential) -> String? { Keychain.read(credential) }
}

struct NoCredentials: CredentialSource {
    func value(for credential: Credential) -> String? { nil }
}

/// Picks the extractor for a link, expands short links first, and runs it.
struct ExtractorRegistry: Sendable {
    let client: HTTPClient
    let credentials: any CredentialSource

    init(client: HTTPClient = HTTPClient(), credentials: any CredentialSource = KeychainCredentials()) {
        self.client = client
        self.credentials = credentials
    }

    static let all: [Platform: any Extractor] = [
        .tikTok: TikTokExtractor(),
        .youTube: YouTubeExtractor(),
        .instagram: InstagramExtractor(),
        .threads: ThreadsExtractor(),
        .x: XExtractor(),
        .reddit: RedditExtractor(),
        .bluesky: BlueskyExtractor(),
        .pinterest: PinterestExtractor(),
        .snapchat: SnapchatExtractor(),
        .kick: KickExtractor(),
        .tumblr: TumblrExtractor(),
        .imgur: ImgurExtractor(),
        .discord: DiscordExtractor(),
        .web: WebExtractor()
    ]

    func extract(_ raw: String) async throws -> Post {
        guard let url = LinkParser.firstURL(in: raw) else { throw StashyError.invalidLink }
        return try await extract(url)
    }

    func extract(_ original: URL) async throws -> Post {
        var url = original
        if LinkParser.isShortLink(url) {
            let expanded = try await client.expand(url)
            url = LinkParser.normalize(expanded.absoluteString) ?? expanded
        }
        let platform = LinkParser.platform(for: url)
        guard let extractor = Self.all[platform] else { throw StashyError.unsupportedLink }
        var post = try await extractor.extract(url, client: client, credentials: credentials)
        post.sourceURL = original
        post.items = post.items.enumerated().map { index, item in
            var copy = item
            copy.index = index
            copy.variants = Self.rank(copy.variants)
            return copy
        }
        if post.items.isEmpty { throw StashyError.noMedia }
        return post
    }

    /// Best first: more pixels, then more bitrate, then larger file. Adaptive codecs that need
    /// muxing rank by their pixels like everything else; the assembler handles the rest.
    static func rank(_ variants: [MediaVariant]) -> [MediaVariant] {
        variants.enumerated().sorted { lhs, rhs in
            if lhs.element.pixels != rhs.element.pixels { return lhs.element.pixels > rhs.element.pixels }
            if (lhs.element.bitrate ?? 0) != (rhs.element.bitrate ?? 0) { return (lhs.element.bitrate ?? 0) > (rhs.element.bitrate ?? 0) }
            if (lhs.element.sizeBytes ?? 0) != (rhs.element.sizeBytes ?? 0) { return (lhs.element.sizeBytes ?? 0) > (rhs.element.sizeBytes ?? 0) }
            let lhsCost = deliveryCost(lhs.element.delivery)
            let rhsCost = deliveryCost(rhs.element.delivery)
            if lhsCost != rhsCost { return lhsCost < rhsCost }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// On an otherwise equal footing a plain file beats a stream beats a pair to mux.
    private static func deliveryCost(_ delivery: MediaDelivery) -> Int {
        switch delivery {
        case .file: 0
        case .hls: 1
        case .muxed: 2
        }
    }
}

// MARK: - Shared building blocks

enum Extract {
    static func photo(_ url: URL, width: Int? = nil, height: Int? = nil, label: String = "original", headers: [String: String] = [:], size: Int64? = nil) -> MediaVariant {
        MediaVariant(delivery: .file(url), width: width, height: height, codec: imageCodec(for: url), container: imageExtension(for: url), sizeBytes: size, label: label, headers: headers, expiresAt: SignedURL.expiry(of: url))
    }

    static func video(_ url: URL, width: Int? = nil, height: Int? = nil, bitrate: Int? = nil, fps: Double? = nil, codec: String? = "H.264", container: String = "mp4", label: String, headers: [String: String] = [:], size: Int64? = nil) -> MediaVariant {
        MediaVariant(delivery: .file(url), width: width, height: height, bitrate: bitrate, fps: fps, codec: codec, container: container, sizeBytes: size, label: label, headers: headers, expiresAt: SignedURL.expiry(of: url))
    }

    static func item(_ kind: MediaKind, _ variants: [MediaVariant], thumbnail: URL? = nil, duration: TimeInterval? = nil, alt: String? = nil) -> MediaItem {
        let first = variants.first
        return MediaItem(index: 0, kind: kind, variants: variants, thumbnailURL: thumbnail ?? (kind == .photo ? first?.delivery.primaryURL : nil), duration: duration, altText: alt)
    }

    static func imageExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "pnj": return "jpg"
        case "png", "gif", "webp", "heic", "avif": return ext
        default: return "jpg"
        }
    }

    static func imageCodec(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "PNG"
        case "gif": "GIF"
        case "webp": "WebP"
        case "heic": "HEIC"
        case "avif": "AVIF"
        default: "JPEG"
        }
    }

    static func codecFamily(_ mime: String) -> String {
        let lower = mime.lowercased()
        if lower.contains("avc1") || lower.contains("h264") { return "H.264" }
        if lower.contains("hvc1") || lower.contains("hev1") || lower.contains("h265") || lower.contains("bytevc1") { return "H.265" }
        if lower.contains("av01") { return "AV1" }
        if lower.contains("vp9") || lower.contains("vp09") { return "VP9" }
        if lower.contains("mp4a") || lower.contains("aac") { return "AAC" }
        if lower.contains("opus") { return "Opus" }
        return mime.split(separator: ";").first.map(String.init) ?? mime
    }

    static func date(fromUnix value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
    }

    static func date(fromISO text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Open Graph / Twitter card metadata, the floor every public page offers.
    static func openGraphItems(html: String, base: URL) -> (items: [MediaItem], title: String?, description: String?, site: String?, image: URL?) {
        var items: [MediaItem] = []
        var title: String?
        var description: String?
        var site: String?
        var firstImage: URL?
        var seen = Set<String>()
        for (name, content) in HTMLText.metaTags(in: html) {
            switch name {
            case "og:title", "twitter:title": if title == nil { title = content }
            case "og:description", "twitter:description", "description": if description == nil { description = content }
            case "og:site_name": site = content
            case "og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream":
                guard let url = URL(string: content, relativeTo: base)?.absoluteURL, seen.insert(url.absoluteString).inserted else { continue }
                let ext = url.pathExtension.lowercased()
                guard ext != "m3u8", ext != "mpd", ext != "swf", !url.path.contains("/embed") else { continue }
                items.append(item(.video, [video(url, label: "og:video")]))
            case "og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src":
                guard let url = URL(string: content, relativeTo: base)?.absoluteURL, seen.insert(url.absoluteString).inserted else { continue }
                if firstImage == nil { firstImage = url }
                items.append(item(.photo, [photo(url, label: "og:image")]))
            default: break
            }
        }
        return (items, title, description, site, firstImage)
    }
}

/// Signed CDN addresses carry their own expiry; knowing it lets the queue re-resolve instead
/// of failing with a 403 an hour later.
enum SignedURL {
    static func expiry(of url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for item in items {
            let name = item.name.lowercased()
            guard ["x-expires", "expire", "expires", "exp", "oe"].contains(name), let value = item.value else { continue }
            if let seconds = Double(value), seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
            if name == "oe", let hex = UInt64(value, radix: 16), hex > 1_000_000_000 { return Date(timeIntervalSince1970: Double(hex)) }
        }
        return nil
    }
}
