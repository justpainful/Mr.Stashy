import Foundation

/// One address a public page exposes as savable media, before Stashy has confirmed it.
struct MediaCandidate: Sendable, Hashable {
    var url: URL
    var declaredType: String?
    var kind: MediaType?
    var width: Int?
    var height: Int?
    var duration: TimeInterval?
    var alt: String?
    var thumbnailURL: URL?
    var bitrate: Int?
    var estimatedBytes: Int64?
    var qualityLabel: String
    var cleanliness: SourceCleanliness = .unknown
    /// Headers the source requires in order to serve this address, such as a `Referer`.
    var headers: [String: String] = [:]

    /// What this candidate actually is.
    ///
    /// Evidence beats a guess. `kind` is inferred from the JSON key an address was found under,
    /// and a key is not a fact: TikTok publishes the post's *music track* under `playUrl`, the
    /// same key other sources use for a video. Trusting the key over the `.mp3` in the address
    /// is what filed a song as the post's video and left people with a saved "video" that was
    /// only sound. The key's hint is used only where the address and the server both say nothing.
    var resolvedType: MediaType {
        if let stated = MediaType.stated(candidateURL: url, declaredType: declaredType) { return stated }
        return kind ?? .photo
    }

    /// A player page, an embed frame, or a tracking pixel is not savable media. Accepting one is
    /// what makes a save fail late, after the user already believes the post was archived.
    var isSavableAddress: Bool {
        let declared = (declaredType ?? "").lowercased()
        if declared.contains("text/html") || declared == "text" || declared.contains("application/xhtml") { return false }
        // An adaptive-stream manifest describes a video; it is not one. Stashy archives files.
        if ["m3u8", "mpd"].contains(url.pathExtension.lowercased()) { return false }
        if declared.contains("mpegurl") || declared.contains("dash+xml") { return false }
        let path = url.path.lowercased()
        for marker in ["/embed/", "/embed?", "/player", "/iframe", "/watch", "/e/"] where path.contains(marker) {
            return false
        }
        if url.host?.lowercased().contains("youtube.com") == true, path.hasPrefix("/embed") { return false }
        return url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
    }
}

extension MediaType {
    /// The kind the declared MIME type or the address states outright, or `nil` when neither
    /// says anything — a signed CDN address with no path extension, typically.
    static func stated(candidateURL url: URL, declaredType: String? = nil) -> MediaType? {
        let declared = (declaredType ?? "").lowercased()
        let ext = url.pathExtension.lowercased()
        if declared.contains("gif") || ext == "gif" { return .gif }
        if declared.hasPrefix("video") || declared.contains("video/") || declared.contains("mpegurl")
            || ["mp4", "mov", "m4v", "webm", "m3u8", "mpd"].contains(ext) { return .video }
        if declared.hasPrefix("audio") || declared.contains("audio/")
            || ["mp3", "m4a", "wav", "aac", "flac", "oga", "ogg", "opus"].contains(ext) { return .audio }
        if declared.hasPrefix("image") || declared.contains("image/")
            || ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "bmp", "tiff"].contains(ext) { return .photo }
        return nil
    }

    /// Chooses a media kind from a declared MIME type first, then the address itself. A source
    /// that states nothing is treated as a picture, which is what a bare CDN address usually is.
    init(candidateURL url: URL, declaredType: String? = nil) {
        self = MediaType.stated(candidateURL: url, declaredType: declaredType) ?? .photo
    }
}

/// Extracts every media address a public HTML page exposes, in the order the document exposes
/// them, using each of the ways a source can publish it. Real pages publish media in more than
/// one way, and a source that changes one of them should not take the whole capture down.
enum PageMediaExtractor {
    static func candidates(in html: String, baseURL: URL) -> [MediaCandidate] {
        var ordered: [MediaCandidate] = []
        var seen = Set<String>()

        func append(_ candidates: [MediaCandidate]) {
            for candidate in candidates where candidate.isSavableAddress {
                let key = candidate.url.absoluteString
                if seen.insert(key).inserted { ordered.append(candidate) }
            }
        }

        let document = OpenGraphDocument(html: html)
        append(document.candidates(relativeTo: baseURL))
        append(JSONLDMediaExtractor.candidates(in: html, baseURL: baseURL))
        append(InlineMediaExtractor.candidates(in: html, baseURL: baseURL))
        append(InlineJSONMediaExtractor.candidates(in: html, baseURL: baseURL))
        return ordered
    }

    /// A page that only offers its own logo, avatar, or share card has not exposed the post.
    /// Treating those as the post is what produced "saved" archives holding a site logo.
    static func isGenericBranding(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        let markers = [
            "logo", "favicon", "sprite", "placeholder", "default_", "/default.",
            "facebook_share_image", "share_image", "opengraph-default", "app-icon", "appicon"
        ]
        return markers.contains { value.contains($0) }
    }
}

// MARK: - schema.org JSON-LD

enum JSONLDMediaExtractor {
    static func candidates(in html: String, baseURL: URL) -> [MediaCandidate] {
        var results: [MediaCandidate] = []
        for payload in scriptPayloads(in: html, type: "application/ld+json") {
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            collect(from: object, baseURL: baseURL, into: &results)
        }
        return results
    }

    private static func collect(from object: Any, baseURL: URL, into results: inout [MediaCandidate]) {
        if let array = object as? [Any] {
            for element in array { collect(from: element, baseURL: baseURL, into: &results) }
            return
        }
        guard let node = object as? [String: Any] else { return }
        let type = (node["@type"] as? String)?.lowercased() ?? ""

        if type.contains("videoobject") {
            if let candidate = candidate(from: node["contentUrl"], baseURL: baseURL, kind: .video, label: "schema.org contentUrl") {
                var enriched = candidate
                enriched.width = intValue(node["width"])
                enriched.height = intValue(node["height"])
                enriched.duration = ISO8601Duration.seconds(node["duration"] as? String)
                enriched.alt = node["name"] as? String ?? node["description"] as? String
                enriched.thumbnailURL = url(from: node["thumbnailUrl"], baseURL: baseURL)
                results.append(enriched)
            } else if let candidate = candidate(from: node["embedUrl"], baseURL: baseURL, kind: .video, label: "schema.org embedUrl") {
                results.append(candidate)
            }
        }
        if type.contains("imageobject") || type.contains("photograph") {
            if let candidate = candidate(from: node["contentUrl"] ?? node["url"], baseURL: baseURL, kind: nil, label: "schema.org image") {
                var enriched = candidate
                enriched.width = intValue(node["width"])
                enriched.height = intValue(node["height"])
                enriched.alt = node["caption"] as? String ?? node["name"] as? String
                results.append(enriched)
            }
        }
        if type.contains("audioobject") {
            if let candidate = candidate(from: node["contentUrl"], baseURL: baseURL, kind: .audio, label: "schema.org audio") {
                results.append(candidate)
            }
        }
        for key in ["image", "video", "audio", "@graph", "mainEntity", "associatedMedia", "hasPart", "itemListElement"] {
            if let nested = node[key] { collect(from: nested, baseURL: baseURL, into: &results) }
        }
    }

    private static func candidate(from value: Any?, baseURL: URL, kind: MediaType?, label: String) -> MediaCandidate? {
        guard let url = url(from: value, baseURL: baseURL) else { return nil }
        return MediaCandidate(url: url, declaredType: nil, kind: kind, qualityLabel: label)
    }

    private static func url(from value: Any?, baseURL: URL) -> URL? {
        if let string = value as? String { return URL(string: string, relativeTo: baseURL)?.absoluteURL }
        if let node = value as? [String: Any] { return url(from: node["contentUrl"] ?? node["url"], baseURL: baseURL) }
        if let array = value as? [Any] { return array.compactMap { url(from: $0, baseURL: baseURL) }.first }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let string = value as? String { return Int(string.filter(\.isNumber)) }
        return nil
    }

    static func scriptPayloads(in html: String, type: String) -> [String] {
        let pattern = "<script[^>]*type\\s*=\\s*[\"']" + NSRegularExpression.escapedPattern(for: type) + "[\"'][^>]*>([\\s\\S]*?)</script>"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let payloadRange = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[payloadRange])
        }
    }
}

enum ISO8601Duration {
    /// Reads the `PT1M30S` form schema.org uses for media duration.
    static func seconds(_ value: String?) -> TimeInterval? {
        guard let value, value.hasPrefix("PT") else { return nil }
        var total: TimeInterval = 0
        var number = ""
        for character in value.dropFirst(2) {
            if character.isNumber || character == "." {
                number.append(character)
            } else {
                guard let amount = Double(number) else { number = ""; continue }
                switch character {
                case "H", "h": total += amount * 3_600
                case "M", "m": total += amount * 60
                case "S", "s": total += amount
                default: break
                }
                number = ""
            }
        }
        return total > 0 ? total : nil
    }
}

// MARK: - Inline HTML media elements

enum InlineMediaExtractor {
    static func candidates(in html: String, baseURL: URL) -> [MediaCandidate] {
        var results: [MediaCandidate] = []
        results.append(contentsOf: elements(in: html, tag: "video", kind: .video, label: "Page video element", baseURL: baseURL))
        results.append(contentsOf: elements(in: html, tag: "audio", kind: .audio, label: "Page audio element", baseURL: baseURL))
        results.append(contentsOf: sources(in: html, baseURL: baseURL))
        results.append(contentsOf: linkedImages(in: html, baseURL: baseURL))
        return results
    }

    private static func elements(in html: String, tag: String, kind: MediaType, label: String, baseURL: URL) -> [MediaCandidate] {
        matches(in: html, pattern: "<" + tag + "\\b[^>]*\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']").compactMap { value in
            guard let url = URL(string: HTMLEntity.decode(value), relativeTo: baseURL)?.absoluteURL else { return nil }
            return MediaCandidate(url: url, declaredType: nil, kind: kind, qualityLabel: label)
        }
    }

    private static func sources(in html: String, baseURL: URL) -> [MediaCandidate] {
        matches(in: html, pattern: "<source\\b[^>]*\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']").compactMap { value in
            guard let url = URL(string: HTMLEntity.decode(value), relativeTo: baseURL)?.absoluteURL else { return nil }
            return MediaCandidate(url: url, declaredType: nil, kind: nil, qualityLabel: "Page source element")
        }
    }

    /// `<link rel="image_src">` is the pre-Open-Graph convention some sources still publish.
    private static func linkedImages(in html: String, baseURL: URL) -> [MediaCandidate] {
        matches(in: html, pattern: "<link\\b[^>]*rel\\s*=\\s*[\"']image_src[\"'][^>]*href\\s*=\\s*[\"']([^\"']+)[\"']").compactMap { value in
            guard let url = URL(string: HTMLEntity.decode(value), relativeTo: baseURL)?.absoluteURL else { return nil }
            return MediaCandidate(url: url, declaredType: nil, kind: .photo, qualityLabel: "Linked source image")
        }
    }

    private static func matches(in html: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[valueRange])
        }
    }
}

// MARK: - Inline JSON payloads

/// Reads media addresses out of the JSON a page embeds in its own `<script>` tags. Several
/// sources publish the post payload there and nowhere else, so skipping it is what makes a
/// perfectly public post look like it has no media.
enum InlineJSONMediaExtractor {
    private static let keys = [
        "playAddr", "downloadAddr", "contentUrl", "video_url", "videoUrl", "hlsUrl", "playUrl",
        "src_url", "image_url", "imageUrl", "media_url_https", "url_overridden_by_dest", "clip_url"
    ]

    /// Keys that name a post's backing track rather than the post. On TikTok the sound is a
    /// first-class object with its own address, and picking it up as the post's media is how a
    /// saved video turned out to be a song.
    private static let soundtrackKeys: Set<String> = ["playUrl"]

    static func candidates(in html: String, baseURL: URL) -> [MediaCandidate] {
        var results: [MediaCandidate] = []
        var seen = Set<String>()
        for key in keys {
            let pattern = "\"" + key + "\"\\s*:\\s*\"([^\"]{8,2048})\""
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex ..< html.endIndex, in: html)
            for match in expression.matches(in: html, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: html) else { continue }
                let raw = JSONStringEscape.unescape(String(html[valueRange]))
                guard raw.hasPrefix("http"),
                      let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                      seen.insert(url.absoluteString).inserted
                else { continue }
                results.append(MediaCandidate(url: url, declaredType: nil, kind: kindFor(key: key), qualityLabel: "Source payload"))
            }
        }
        return results
    }

    /// The kind a key suggests, used only when the address itself states nothing. `playUrl` is a
    /// soundtrack, not a video: naming it one is what made a saved TikTok play as a song over a
    /// black screen. Typed honestly, the video filter drops it and the capture falls through to
    /// the path that saves what the post actually shows.
    private static func kindFor(key: String) -> MediaType? {
        if soundtrackKeys.contains(key) { return .audio }
        switch key {
        case "playAddr", "downloadAddr", "video_url", "videoUrl", "hlsUrl", "clip_url": return .video
        case "image_url", "imageUrl", "media_url_https": return .photo
        default: return nil
        }
    }
}

// MARK: - Signed URL expiry

enum SignedURLExpiry {
    private static let parameterNames = ["x-expires", "expires", "exp", "oe", "e", "se"]

    /// Reads the expiry a signed CDN address advertises so the app can tell the user a link
    /// went stale instead of reporting an unexplained network failure.
    static func date(in url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for item in items where parameterNames.contains(item.name.lowercased()) {
            guard let value = item.value else { continue }
            if let seconds = TimeInterval(value), seconds > 1_000_000_000, seconds < 4_000_000_000 {
                return Date(timeIntervalSince1970: seconds)
            }
            // Some hosts publish the expiry as a hex timestamp.
            if let hex = UInt64(value, radix: 16), hex > 1_000_000_000, hex < 4_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(hex))
            }
        }
        return nil
    }
}

// MARK: - Login and consent walls

enum AccessWallDetector {
    private static let markers = [
        "accounts/login", "/login?", "login_and_signup", "please log in", "log in to continue",
        "sign up to continue", "restricted_page", "age-restricted",
        "content isn't available", "content is not available", "gdpr-consent",
        // Meta stopped shipping the older markers. A signed-out request for an Instagram or
        // Threads post now returns their app shell, whose route table names the login page —
        // checked here so the reason reaches the person as "this source wants an account"
        // rather than as "this post has no media", which blames the post.
        "polaris.loginpage", "logincipcanvasfingerprint", "fetaloginstatusdata"
    ]

    /// Phrases that identify a private post. A bare "private" also matches ordinary payload
    /// keys such as `"is_private":false`, which turned public posts into "this post is private".
    private static let privateMarkers = [
        "this account is private", "this post is private", "sorry, this page isn", "account is private"
    ]

    /// Sources answer a login or consent interstitial with HTTP 200, so status code alone
    /// cannot tell the user why a public-looking link produced nothing.
    static func wall(in page: FetchedPage, requested: URL) -> ResolverError? {
        let lowered = page.html.lowercased()
        let landedElsewhere = page.url.path.count <= 1 && requested.path.count > 1
        if privateMarkers.contains(where: { lowered.contains($0) }) { return .contentPrivate }
        if markers.contains(where: { lowered.contains($0) }) { return .authenticationRequired }
        return landedElsewhere ? .contentNotFound : nil
    }
}
