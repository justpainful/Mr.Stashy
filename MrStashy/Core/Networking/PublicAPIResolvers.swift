import Foundation

// Two sources whose own public, unauthenticated APIs describe a post completely: Reddit and
// Bluesky. Both are read here through the endpoint the platform publishes for anyone — no
// account, no key, no stored session — and both return the real files rather than a share card,
// which is the difference between supporting a platform and listing it.

// MARK: - Reddit

struct RedditResolver: PlatformResolver {
    let platform: Platform = .reddit
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .reddit, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .reddit }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        let postID = try await identifier(for: request.canonicalURL)
        // Reddit answers `/comments/<id>.json` for anyone. `raw_json=1` stops it HTML-escaping
        // the media addresses, which is what turns a preview link into a dead one.
        guard let endpoint = URL(string: "https://www.reddit.com/comments/\(postID).json?raw_json=1") else {
            throw ResolverError.invalidURL
        }
        // Reddit refuses a generic client identity, so the documented browser profile is used.
        let data = try await engine.fetcher.json(at: endpoint, profile: .browser)
        guard let listings = try? JSONDecoder().decode([RedditListing].self, from: data),
              let post = listings.first?.data.children.first?.data
        else { throw ResolverError.platformChanged }

        if post.isGated { throw ResolverError.contentPrivate }
        var warnings: [String] = []
        let candidates = post.mediaCandidates(warnings: &warnings)
        guard !candidates.isEmpty else { throw ResolverError.mediaMissing }
        return try await engine.post(
            from: candidates,
            request: request,
            page: nil,
            document: nil,
            resolverVersion: "reddit-public-json.1",
            author: post.resolvedAuthor(),
            text: post.archivedText,
            createdAt: post.created.map { Date(timeIntervalSince1970: $0) },
            extraWarnings: warnings
        )
    }

    /// Reddit's share sheet hands out `/r/<sub>/s/<token>`, which carries no post identifier at
    /// all. Following it once is the only way to learn what it points at, and it is what the
    /// person meant when they pasted the link.
    private func identifier(for url: URL) async throws -> String {
        if let postID = Self.postID(in: url) { return postID }
        guard url.pathComponents.contains("s") else { throw ResolverError.invalidURL }
        let page = try await engine.fetcher.page(at: url, profile: .browser)
        if let postID = Self.postID(in: page.url) { return postID }
        if let canonical = OpenGraphDocument(html: page.html).canonicalURL(relativeTo: page.url),
           let postID = Self.postID(in: canonical) {
            return postID
        }
        throw ResolverError.invalidURL
    }

    /// The base-36 identifier in `/r/<sub>/comments/<id>/<slug>`, `/comments/<id>`, or a
    /// `redd.it/<id>` short link.
    static func postID(in url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if let index = components.firstIndex(of: "comments"), components.index(after: index) < components.endIndex {
            return components[components.index(after: index)]
        }
        if url.host?.lowercased().hasSuffix("redd.it") == true, let first = components.first, !first.isEmpty {
            return first
        }
        // `/s/<share-id>` is a share redirect, not a post identifier; the canonicaliser expands
        // those before they reach here, so anything left is unusable.
        return nil
    }
}

private struct RedditListing: Decodable {
    struct Container: Decodable { let children: [Child] }
    struct Child: Decodable { let data: RedditPost }
    let data: Container
}

private struct RedditPost: Decodable {
    struct Preview: Decodable {
        struct Image: Decodable {
            struct Source: Decodable { let url: String?; let width: Int?; let height: Int? }
            let source: Source?
            let variants: [String: Variant]?
        }
        struct Variant: Decodable {
            struct Source: Decodable { let url: String?; let width: Int?; let height: Int? }
            let source: Source?
        }
        struct RedditVideoPreview: Decodable {
            let fallbackURL: String?
            let width: Int?
            let height: Int?
            let duration: Int?
            enum CodingKeys: String, CodingKey {
                case fallbackURL = "fallback_url"
                case width, height, duration
            }
        }
        let images: [Image]?
        let redditVideoPreview: RedditVideoPreview?
        enum CodingKeys: String, CodingKey {
            case images
            case redditVideoPreview = "reddit_video_preview"
        }
    }

    struct Media: Decodable {
        struct RedditVideo: Decodable {
            let fallbackURL: String?
            let width: Int?
            let height: Int?
            let duration: Int?
            let isGIF: Bool?
            enum CodingKeys: String, CodingKey {
                case fallbackURL = "fallback_url"
                case width, height, duration
                case isGIF = "is_gif"
            }
        }
        let redditVideo: RedditVideo?
        enum CodingKeys: String, CodingKey { case redditVideo = "reddit_video" }
    }

    struct GalleryData: Decodable {
        struct Item: Decodable {
            let mediaID: String?
            enum CodingKeys: String, CodingKey { case mediaID = "media_id" }
        }
        let items: [Item]?
    }

    struct MediaMetadata: Decodable {
        struct Largest: Decodable { let u: String?; let gif: String?; let mp4: String?; let x: Int?; let y: Int? }
        let s: Largest?
        let m: String?
        let status: String?
    }

    let title: String?
    let selftext: String?
    let author: String?
    let permalink: String?
    let subreddit: String?
    let created: Double?
    let over18: Bool?
    let removedByCategory: String?
    let urlOverriddenByDest: String?
    let postHint: String?
    let preview: Preview?
    let media: Media?
    let isGallery: Bool?
    let galleryData: GalleryData?
    let mediaMetadata: [String: MediaMetadata]?

    enum CodingKeys: String, CodingKey {
        case title, selftext, author, permalink, subreddit, preview, media
        case created = "created_utc"
        case over18 = "over_18"
        case removedByCategory = "removed_by_category"
        case urlOverriddenByDest = "url_overridden_by_dest"
        case postHint = "post_hint"
        case isGallery = "is_gallery"
        case galleryData = "gallery_data"
        case mediaMetadata = "media_metadata"
    }

    /// A post Reddit has taken down publishes no media, and saying "no media" for that blames
    /// the post rather than naming what happened.
    var isGated: Bool { removedByCategory != nil }

    var archivedText: String {
        let parts = [title, selftext].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: "\n\n")
    }

    func resolvedAuthor() -> ResolvedAuthor {
        let handle = author ?? "reddit"
        return ResolvedAuthor(
            platformID: nil,
            displayName: subreddit.map { "r/\($0)" } ?? handle,
            username: handle,
            avatarURL: nil,
            profileURL: URL(string: "https://www.reddit.com/user/\(handle)"),
            badges: over18 == true ? ["nsfw"] : []
        )
    }

    func mediaCandidates(warnings: inout [String]) -> [MediaCandidate] {
        var results: [MediaCandidate] = []

        // A gallery is the only shape that carries more than one file, and its order is the one
        // the author chose, so it is preserved exactly.
        if isGallery == true, let items = galleryData?.items, let metadata = mediaMetadata {
            for item in items {
                guard let identifier = item.mediaID, let entry = metadata[identifier] else { continue }
                let address = entry.s?.mp4 ?? entry.s?.gif ?? entry.s?.u
                guard let raw = address, let url = URL(string: HTMLEntity.decode(raw)) else { continue }
                results.append(MediaCandidate(
                    url: url,
                    declaredType: nil,
                    kind: entry.s?.mp4 != nil ? .video : (entry.s?.gif != nil ? .gif : .photo),
                    width: entry.s?.x, height: entry.s?.y,
                    qualityLabel: "Gallery original",
                    cleanliness: .original
                ))
            }
            if !results.isEmpty { return results }
        }

        if let video = media?.redditVideo, let raw = video.fallbackURL, let url = URL(string: raw) {
            // Reddit stores a post's picture and sound as two separate DASH files. The one
            // address it publishes is the picture, so the capture says the sound is not in it
            // rather than letting a silent file look like a bug.
            if video.isGIF != true { warnings.append(L10n.value("resolver.warning.redditSilentVideo")) }
            results.append(MediaCandidate(
                url: url, declaredType: "video/mp4", kind: .video,
                width: video.width, height: video.height,
                duration: video.duration.map(TimeInterval.init),
                thumbnailURL: previewImageURL(),
                qualityLabel: "Reddit hosted video",
                cleanliness: .original
            ))
            return results
        }

        if let raw = urlOverriddenByDest, let url = URL(string: raw) {
            let extensionName = url.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "gif", "gifv", "webp", "mp4"].contains(extensionName) {
                // `.gifv` is an Imgur video wearing an image extension.
                let normalized = extensionName == "gifv"
                    ? URL(string: raw.replacingOccurrences(of: ".gifv", with: ".mp4")) ?? url
                    : url
                results.append(MediaCandidate(
                    url: normalized, declaredType: nil, kind: nil,
                    width: preview?.images?.first?.source?.width,
                    height: preview?.images?.first?.source?.height,
                    qualityLabel: "Linked original",
                    cleanliness: .original
                ))
            }
        }

        if results.isEmpty, let raw = preview?.redditVideoPreview?.fallbackURL, let url = URL(string: raw) {
            results.append(MediaCandidate(
                url: url, declaredType: "video/mp4", kind: .video,
                width: preview?.redditVideoPreview?.width,
                height: preview?.redditVideoPreview?.height,
                duration: preview?.redditVideoPreview?.duration.map(TimeInterval.init),
                qualityLabel: "Reddit video preview"
            ))
        }

        if results.isEmpty, let url = previewImageURL() {
            results.append(MediaCandidate(
                url: url, declaredType: nil, kind: .photo,
                width: preview?.images?.first?.source?.width,
                height: preview?.images?.first?.source?.height,
                qualityLabel: "Preview image"
            ))
        }
        return results
    }

    private func previewImageURL() -> URL? {
        guard let raw = preview?.images?.first?.source?.url else { return nil }
        return URL(string: HTMLEntity.decode(raw))
    }
}

// MARK: - Bluesky

struct BlueskyResolver: PlatformResolver {
    let platform: Platform = .bluesky
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .bluesky, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .bluesky }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        guard let reference = Self.reference(in: request.canonicalURL) else { throw ResolverError.invalidURL }
        // A post is addressed by the account's decentralised identifier, so a handle in the link
        // is exchanged for one first. Both endpoints are Bluesky's own public read API.
        let identifier = reference.handle.hasPrefix("did:")
            ? reference.handle
            : try await resolveHandle(reference.handle)
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread")
        components?.queryItems = [
            URLQueryItem(name: "uri", value: "at://\(identifier)/app.bsky.feed.post/\(reference.recordKey)"),
            URLQueryItem(name: "depth", value: "0"),
            URLQueryItem(name: "parentHeight", value: "0")
        ]
        guard let endpoint = components?.url else { throw ResolverError.invalidURL }
        let data = try await engine.fetcher.json(at: endpoint)
        guard let response = try? JSONDecoder().decode(BlueskyThreadResponse.self, from: data),
              let post = response.thread.post
        else { throw ResolverError.contentNotFound }

        var warnings: [String] = []
        let candidates = post.mediaCandidates(warnings: &warnings)
        guard !candidates.isEmpty else { throw ResolverError.mediaMissing }
        return try await engine.post(
            from: candidates,
            request: request,
            page: nil,
            document: nil,
            resolverVersion: "bluesky-public-api.1",
            author: post.resolvedAuthor(),
            text: post.record?.text ?? "",
            createdAt: post.record?.createdAt.flatMap(ISO8601DateFormatter.blueskyDate),
            extraWarnings: warnings
        )
    }

    private func resolveHandle(_ handle: String) async throws -> String {
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle")
        components?.queryItems = [URLQueryItem(name: "handle", value: handle)]
        guard let endpoint = components?.url else { throw ResolverError.invalidURL }
        let data = try await engine.fetcher.json(at: endpoint)
        struct Response: Decodable { let did: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ResolverError.contentNotFound
        }
        return response.did
    }

    /// `https://bsky.app/profile/<handle-or-did>/post/<rkey>`.
    static func reference(in url: URL) -> (handle: String, recordKey: String)? {
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let profileIndex = components.firstIndex(of: "profile"),
              components.index(after: profileIndex) < components.endIndex,
              let postIndex = components.firstIndex(of: "post"),
              components.index(after: postIndex) < components.endIndex
        else { return nil }
        let handle = components[components.index(after: profileIndex)]
        let recordKey = components[components.index(after: postIndex)]
        guard !handle.isEmpty, !recordKey.isEmpty else { return nil }
        return (handle, recordKey)
    }
}

private extension ISO8601DateFormatter {
    /// Bluesky timestamps carry fractional seconds; the plain formatter rejects those.
    static func blueskyDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct BlueskyThreadResponse: Decodable {
    struct Thread: Decodable { let post: BlueskyPost? }
    let thread: Thread
}

private struct BlueskyPost: Decodable {
    struct Author: Decodable {
        let did: String?
        let handle: String?
        let displayName: String?
        let avatar: String?
        let labels: [Label]?
        struct Label: Decodable { let val: String? }
    }

    struct Record: Decodable {
        let text: String?
        let createdAt: String?
    }

    struct Embed: Decodable {
        struct Image: Decodable {
            struct AspectRatio: Decodable { let width: Int?; let height: Int? }
            let thumb: String?
            let fullsize: String?
            let alt: String?
            let aspectRatio: AspectRatio?
        }
        struct MediaContainer: Decodable {
            let images: [Image]?
            let playlist: String?
            let thumbnail: String?
            let alt: String?
        }
        let type: String?
        let images: [Image]?
        let playlist: String?
        let thumbnail: String?
        let alt: String?
        /// A quote post nests the pictures one level deeper, under `media`.
        let media: MediaContainer?

        enum CodingKeys: String, CodingKey {
            case type = "$type"
            case images, playlist, thumbnail, alt, media
        }
    }

    let author: Author?
    let record: Record?
    let embed: Embed?

    func resolvedAuthor() -> ResolvedAuthor {
        ResolvedAuthor(
            platformID: author?.did,
            displayName: author?.displayName?.isEmpty == false ? author!.displayName! : (author?.handle ?? "Bluesky"),
            username: author?.handle,
            avatarURL: author?.avatar.flatMap(URL.init(string:)),
            profileURL: author?.handle.flatMap { URL(string: "https://bsky.app/profile/\($0)") },
            badges: author?.labels?.compactMap(\.val) ?? []
        )
    }

    func mediaCandidates(warnings: inout [String]) -> [MediaCandidate] {
        var results: [MediaCandidate] = []
        let images = embed?.images ?? embed?.media?.images ?? []
        for image in images {
            guard let raw = image.fullsize ?? image.thumb, let url = URL(string: raw) else { continue }
            results.append(MediaCandidate(
                url: url, declaredType: nil, kind: .photo,
                width: image.aspectRatio?.width, height: image.aspectRatio?.height,
                alt: image.alt,
                qualityLabel: "Full-size image",
                cleanliness: .original
            ))
        }
        if results.isEmpty {
            // Bluesky publishes video as an adaptive playlist, which describes a video without
            // being one. The poster frame is saved and the capture says so, rather than
            // presenting a manifest file as the video.
            let playlist = embed?.playlist ?? embed?.media?.playlist
            let thumbnail = embed?.thumbnail ?? embed?.media?.thumbnail
            if playlist != nil, let raw = thumbnail, let url = URL(string: raw) {
                warnings.append(L10n.value("resolver.warning.adaptiveStream"))
                results.append(MediaCandidate(
                    url: url, declaredType: nil, kind: .photo,
                    alt: embed?.alt ?? embed?.media?.alt,
                    qualityLabel: "Video poster frame"
                ))
            }
        }
        return results
    }
}

// MARK: - Tumblr

/// Tumblr publishes no usable public API — its own `api/v2` wants a key and its oEmbed endpoint
/// answers with an error page — but a post page does serve every image it holds, at several
/// sizes, from `media.tumblr.com`. This reads those directly and keeps the largest of each.
struct TumblrResolver: PlatformResolver {
    let platform: Platform = .tumblr
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .tumblr, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .tumblr }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        // The browser profile, not the crawler one: Tumblr answers the crawler identity with a
        // content screen and the browser identity with the post.
        let page = try await engine.fetcher.firstUsablePage(
            at: request.canonicalURL,
            profiles: [.browser, .metadataCrawler]
        ) { candidate in
            !TumblrMedia.candidates(in: candidate.html).isEmpty
        }

        var candidates = TumblrMedia.candidates(in: page.html)
        if candidates.isEmpty {
            // Nothing of the post's own; fall back to whatever the page published about itself,
            // which the shared engine already knows how to read.
            candidates = PageMediaExtractor.candidates(in: page.html, baseURL: page.url)
        }
        guard !candidates.isEmpty else {
            if let wall = AccessWallDetector.wall(in: page, requested: request.canonicalURL) { throw wall }
            throw ResolverError.mediaMissing
        }
        let document = OpenGraphDocument(html: page.html)
        return try await engine.post(
            from: candidates,
            request: request,
            page: page,
            document: document,
            resolverVersion: "tumblr-post-media.1",
            author: TumblrMedia.author(for: request.canonicalURL, document: document),
            text: document.description ?? document.title ?? ""
        )
    }
}

/// Reads `media.tumblr.com` addresses out of a served post page.
///
/// Tumblr renders the same picture at several sizes and gives each its own filename, so the
/// variants cannot be derived from one another — they have to be collected and compared. The
/// segment before the size is stable per image, which is what groups them.
enum TumblrMedia {
    /// `pnj` is Tumblr's own extension for a PNG delivered as WebP, and it is what most of their
    /// images actually end in — leaving it out matched nothing at all on a real post.
    private static let pattern =
        #"https://[0-9a-z.]*media\.tumblr\.com/([0-9a-f]+/[0-9a-f-]+)/(s(\d+)x(\d+)[^/"']*)/([^"'\s)]+?\.(?:pnj|jpe?g|png|gifv|gif|mp4|webp|webm))"#

    static func candidates(in html: String) -> [MediaCandidate] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex ..< html.endIndex, in: html)

        /// The largest rendition seen for each image, in the order the images first appear.
        var bestByImage: [String: (url: URL, width: Int, height: Int)] = [:]
        var order: [String] = []

        for match in expression.matches(in: html, range: range) {
            guard let whole = Range(match.range, in: html),
                  let identifierRange = Range(match.range(at: 1), in: html),
                  let sizeRange = Range(match.range(at: 2), in: html),
                  let widthRange = Range(match.range(at: 3), in: html),
                  let heightRange = Range(match.range(at: 4), in: html),
                  let url = URL(string: String(html[whole]))
            else { continue }
            let identifier = String(html[identifierRange])
            let width = Int(html[widthRange]) ?? 0
            let height = Int(html[heightRange]) ?? 0
            // Site furniture, not the post. A tiny rendition is a thumbnail, and Tumblr marks a
            // centre-cropped square — which is what it serves avatars as — with a `u_c` suffix
            // on the size segment.
            guard width >= 250, height >= 150 else { continue }
            guard !String(html[sizeRange]).contains("u_c") else { continue }
            if order.firstIndex(of: identifier) == nil { order.append(identifier) }
            if let existing = bestByImage[identifier], existing.width >= width { continue }
            bestByImage[identifier] = (url, width, height)
        }

        return order.compactMap { identifier in
            guard let best = bestByImage[identifier] else { return nil }
            return MediaCandidate(
                url: best.url,
                declaredType: nil,
                kind: nil,
                width: best.width,
                height: best.height,
                qualityLabel: "Largest published size",
                cleanliness: .original
            )
        }
    }

    /// `www.tumblr.com/<blog>/<id>` names the blog in its path, which is the only author the
    /// page reliably states.
    static func author(for url: URL, document: OpenGraphDocument) -> ResolvedAuthor {
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let blog = segments.first
        return ResolvedAuthor(
            platformID: nil,
            displayName: document.siteName.flatMap { $0 == "Tumblr" ? nil : $0 } ?? blog ?? "Tumblr",
            username: blog,
            avatarURL: blog.flatMap { URL(string: "https://api.tumblr.com/v2/blog/\($0)/avatar/96") },
            profileURL: blog.flatMap { URL(string: "https://www.tumblr.com/\($0)") },
            badges: []
        )
    }
}
