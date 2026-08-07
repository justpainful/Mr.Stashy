import Foundation

// Every adapter here reads a public post through the source's own published surface: its
// oEmbed endpoint, its documented public JSON endpoint, or the metadata the page itself
// publishes for link previews. None of them signs in, replays a stored session, or works
// around an access control. When a source genuinely requires an account, the adapter says so
// with a precise error instead of returning an empty result.

// MARK: - TikTok

struct TikTokResolver: PlatformResolver {
    let platform: Platform = .tikTok
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .tikTok, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .tikTok }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        let metadata = try? await oEmbed(for: request.canonicalURL)
        var warnings: [String] = []

        // TikTok publishes the playable address inside the page payload it renders for a
        // browser. The signed address only answers when the request carries the post it came
        // from as its referrer, so that header travels with the variant into the download.
        let referer = request.canonicalURL
        let page = try? await engine.fetcher.page(at: request.canonicalURL, profile: .browser)
        if let page {
            var videoCandidates = InlineJSONMediaExtractor.candidates(in: page.html, baseURL: page.url)
                .filter { $0.resolvedType == .video }
            if !videoCandidates.isEmpty {
                videoCandidates = videoCandidates.map { candidate in
                    var copy = candidate
                    copy.headers["Referer"] = referer.absoluteString
                    copy.headers["User-Agent"] = FetchProfile.browser.userAgent
                    copy.qualityLabel = "Public source video"
                    copy.thumbnailURL = metadata?.thumbnailURL
                    return copy
                }
                let verified = await engine.verify(Array(videoCandidates.prefix(3)))
                if let best = verified.first {
                    return try await engine.post(
                        from: [best],
                        request: request,
                        page: page,
                        document: OpenGraphDocument(html: page.html),
                        resolverVersion: "tiktok-public-payload.2",
                        author: metadata?.author(for: request.canonicalURL),
                        text: metadata?.title ?? "",
                        extraWarnings: warnings
                    )
                }
            }
            if let wall = AccessWallDetector.wall(in: page, requested: request.canonicalURL) { throw wall }
        }

        // The playable address was not reachable through the page payload. TikTok still
        // publishes a cover image, and saving that is a legitimate outcome only if the app says
        // plainly that is what it is. The saying-so happens *after* the fallback, because the
        // fallback scan can itself turn up a video — announcing cover-only up front labelled
        // successful video captures as failures.
        let coverPage = try await engine.fetcher.firstUsablePage(
            at: request.canonicalURL,
            profiles: [.metadataCrawler, .browser]
        ) { candidatePage in
            !PageMediaExtractor.candidates(in: candidatePage.html, baseURL: candidatePage.url).isEmpty
        }
        var candidates = PageMediaExtractor.candidates(in: coverPage.html, baseURL: coverPage.url)
        if candidates.isEmpty, let thumbnail = metadata?.thumbnailURL {
            candidates = [MediaCandidate(url: thumbnail, declaredType: "image", kind: .photo, qualityLabel: "Cover image")]
        }
        guard !candidates.isEmpty else {
            if let wall = AccessWallDetector.wall(in: coverPage, requested: request.canonicalURL) { throw wall }
            throw ResolverError.platformChanged
        }
        var post = try await engine.post(
            from: candidates,
            request: request,
            page: coverPage,
            document: OpenGraphDocument(html: coverPage.html),
            resolverVersion: "tiktok-cover.3",
            author: metadata?.author(for: request.canonicalURL),
            text: metadata?.title ?? "",
            extraWarnings: warnings
        )
        // Only what actually survived verification decides the wording.
        if !post.media.contains(where: { $0.type == .video || $0.type == .audio }) {
            post.warnings.append(L10n.value("resolver.warning.tikTokCoverOnly"))
        }
        return post
    }

    /// TikTok's documented public oEmbed endpoint. It needs no key and no account.
    private func oEmbed(for url: URL) async throws -> OEmbedMetadata {
        var components = URLComponents(string: "https://www.tiktok.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let endpoint = components?.url else { throw ResolverError.invalidURL }
        let data = try await engine.fetcher.json(at: endpoint)
        return try JSONDecoder().decode(OEmbedMetadata.self, from: data)
    }
}

struct OEmbedMetadata: Decodable, Sendable {
    var title: String?
    var authorName: String?
    var authorURL: String?
    var thumbnailURLString: String?
    var width: Int?
    var height: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
        case authorURL = "author_url"
        case thumbnailURLString = "thumbnail_url"
        case width, height
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        authorName = try? values.decodeIfPresent(String.self, forKey: .authorName)
        authorURL = try? values.decodeIfPresent(String.self, forKey: .authorURL)
        thumbnailURLString = try? values.decodeIfPresent(String.self, forKey: .thumbnailURLString)
        // Some providers answer with a percentage string rather than a number.
        width = try? values.decodeIfPresent(Int.self, forKey: .width)
        height = try? values.decodeIfPresent(Int.self, forKey: .height)
    }

    var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }

    func author(for source: URL) -> ResolvedAuthor {
        let profile = authorURL.flatMap(URL.init(string:))
        return ResolvedAuthor(
            platformID: nil,
            displayName: authorName ?? source.host ?? "",
            username: profile?.lastPathComponent.replacingOccurrences(of: "@", with: ""),
            avatarURL: nil,
            profileURL: profile,
            badges: []
        )
    }
}

// MARK: - Instagram

struct InstagramResolver: PlatformResolver {
    let platform: Platform = .instagram
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .instagram, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .instagram }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        do {
            var post = try await engine.resolvePage(
                request,
                profiles: [.metadataCrawler, .browser],
                resolverVersion: "instagram-public-page.3"
            )
            // Instagram publishes exactly one preview image for a whole post, whatever it holds.
            // A ten-photo carousel and a Reel both arrive here as a single still, and reporting
            // that as a finished capture is how someone ends up believing a JPEG is their video.
            if post.media.count == 1, post.media.allSatisfy({ $0.type == .photo }) {
                post.warnings.append(L10n.value("resolver.warning.previewOnly"))
            }
            return post
        } catch let error as ResolverError where error == .mediaMissing {
            // Instagram answers a signed-out request for a gated post with HTTP 200 and a login
            // page. Reporting "no media" for that would blame the post instead of the wall.
            throw ResolverError.authenticationRequired
        }
    }
}

// MARK: - X

struct XResolver: PlatformResolver {
    let platform: Platform = .x
    private let engine: PageResolutionEngine
    private let client: any ResolverHTTPClient
    private let credentials: any ResolverCredentialProvider

    init(
        client: any ResolverHTTPClient = URLSessionResolverHTTPClient(),
        credentials: any ResolverCredentialProvider = KeychainResolverCredentialProvider(),
        prober: any MediaProbing = PassthroughMediaProber()
    ) {
        engine = PageResolutionEngine(platform: .x, client: client, prober: prober)
        self.client = client
        self.credentials = credentials
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .x }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        if let token = credentials.value(for: .xBearerToken) {
            return try await resolveViaOfficialAPI(request, token: token)
        }
        if let postID = Self.postID(in: request.canonicalURL),
           let post = try? await resolveViaPublicSyndication(request, postID: postID) {
            return post
        }
        return try await engine.resolvePage(request, profiles: [.metadataCrawler, .browser], resolverVersion: "x-public-page.2")
    }

    static func postID(in url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              components.index(after: index) < components.endIndex
        else { return nil }
        let candidate = components[components.index(after: index)]
        return candidate.allSatisfy(\.isNumber) && !candidate.isEmpty ? candidate : nil
    }

    /// The endpoint X's own embedded-post widget calls. It is public, unauthenticated, and
    /// returns the ordered media a post exposes, which the preview tags alone never do.
    private func resolveViaPublicSyndication(_ request: ResolveRequest, postID: String) async throws -> ResolvedPost {
        var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")
        components?.queryItems = [
            URLQueryItem(name: "id", value: postID),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "token", value: XSyndicationToken.value(for: postID))
        ]
        guard let endpoint = components?.url else { throw ResolverError.invalidURL }
        let data = try await engine.fetcher.json(at: endpoint, profile: .browser)
        let payload = try JSONDecoder().decode(XSyndicationPost.self, from: data)
        let candidates = payload.mediaCandidates()
        guard !candidates.isEmpty else { throw ResolverError.mediaMissing }
        return try await engine.post(
            from: candidates,
            request: request,
            page: nil,
            document: nil,
            resolverVersion: "x-public-syndication.1",
            author: payload.resolvedAuthor(),
            text: payload.text ?? "",
            createdAt: payload.createdAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    private func resolveViaOfficialAPI(_ request: ResolveRequest, token: String) async throws -> ResolvedPost {
        guard let postID = Self.postID(in: request.canonicalURL) else { throw ResolverError.invalidURL }
        var components = URLComponents(string: "https://api.x.com/2/tweets/\(postID)")
        components?.queryItems = [
            URLQueryItem(name: "expansions", value: "attachments.media_keys,author_id"),
            URLQueryItem(name: "tweet.fields", value: "attachments,author_id,created_at"),
            URLQueryItem(name: "media.fields", value: "alt_text,duration_ms,height,media_key,preview_image_url,type,url,variants,width"),
            URLQueryItem(name: "user.fields", value: "id,name,profile_image_url,username")
        ]
        guard let endpoint = components?.url else { throw ResolverError.invalidURL }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.setValue(token.hasPrefix("Bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.applyProfile(.archiveClient)
        let (data, response) = try await client.data(for: urlRequest)
        try ResolverResponseValidator.validate(response)
        let payload = try JSONDecoder().decode(XAPIPostResponse.self, from: data)
        var mediaByKey: [String: XAPIMedia] = [:]
        for media in payload.includes?.media ?? [] {
            // Keep the first occurrence: the attachment list determines the visible order,
            // and a malformed duplicate must not crash the client or change that order.
            if mediaByKey[media.mediaKey] == nil { mediaByKey[media.mediaKey] = media }
        }
        let media = (payload.data.attachments?.mediaKeys ?? []).enumerated().compactMap { index, key in
            mediaByKey[key].flatMap { $0.resolvedMedia(orderIndex: index) }
        }
        guard !media.isEmpty else { throw ResolverError.mediaMissing }
        let author = payload.includes?.users?.first(where: { $0.id == payload.data.authorID })
        return ResolvedPost(
            id: UUID(), platform: .x, originalURL: request.originalURL, canonicalURL: request.canonicalURL,
            author: ResolvedAuthor(
                platformID: author?.id,
                displayName: author?.name ?? request.canonicalURL.host ?? "X",
                username: author?.username,
                avatarURL: author?.profileImageURL.flatMap(URL.init(string:)),
                profileURL: author?.username.flatMap { URL(string: "https://x.com/\($0)") },
                badges: []
            ),
            text: payload.data.text,
            createdAt: payload.data.createdAt.flatMap { ISO8601DateFormatter().date(from: $0) },
            fetchedAt: .now,
            quotedPost: nil,
            media: media,
            resolverVersion: "x-api-v2.1",
            warnings: []
        )
    }
}

/// Reproduces the token X's embed script derives from a post identifier.
enum XSyndicationToken {
    static func value(for postID: String) -> String {
        // A post identifier arrives from a pasted address and is not length-checked upstream,
        // so an absurdly long run of digits must not reach the `Int` conversion below, where
        // it would trap and take the app down.
        guard postID.count <= 20, let numeric = Double(postID), numeric > 0, numeric.isFinite else { return "a" }
        let scaled = (numeric / 1e15) * Double.pi
        guard scaled.isFinite, scaled < 1e15 else { return "a" }
        let encoded = base36(scaled)
            .replacingOccurrences(of: "0", with: "")
            .replacingOccurrences(of: ".", with: "")
        return encoded.isEmpty ? "a" : encoded
    }

    private static func base36(_ value: Double) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let floor = value.rounded(.down)
        guard floor >= 0, floor < Double(Int.max) else { return "0" }
        var integerPart = Int(floor)
        var fraction = value - Double(integerPart)
        var whole = integerPart == 0 ? "0" : ""
        while integerPart > 0 {
            whole = String(digits[integerPart % 36]) + whole
            integerPart /= 36
        }
        var result = whole + "."
        var steps = 0
        while fraction > 0, steps < 12 {
            fraction *= 36
            let digit = Int(fraction.rounded(.down))
            guard digit >= 0, digit < 36 else { break }
            result.append(digits[digit])
            fraction -= Double(digit)
            steps += 1
        }
        return result
    }
}

// MARK: - Pinterest

struct PinterestResolver: PlatformResolver {
    let platform: Platform = .pinterest
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .pinterest, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .pinterest }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        // A Pinterest pin page renders in the browser, so the page's preview tags describe
        // Pinterest rather than the pin. The widget endpoint its own embeds call does describe
        // the pin, and it needs no key.
        if let pinID = Self.pinID(in: request.canonicalURL),
           let post = try? await resolveViaWidget(request, pinID: pinID) {
            return post
        }
        return try await engine.resolvePage(request, resolverVersion: "pinterest-public-page.2")
    }

    static func pinID(in url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "pin"), components.index(after: index) < components.endIndex else { return nil }
        let candidate = components[components.index(after: index)]
        let digits = candidate.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private func resolveViaWidget(_ request: ResolveRequest, pinID: String) async throws -> ResolvedPost {
        var components = URLComponents(string: "https://widgets.pinterest.com/v3/pidgets/pins/info/")
        components?.queryItems = [URLQueryItem(name: "pin_ids", value: pinID)]
        guard let endpoint = components?.url else { throw ResolverError.invalidURL }
        let data = try await engine.fetcher.json(at: endpoint, profile: .browser)
        let payload = try JSONDecoder().decode(PinterestWidgetResponse.self, from: data)
        guard let pin = payload.pins.first, pin.error == nil else { throw ResolverError.contentNotFound }
        let candidates = pin.mediaCandidates()
        guard !candidates.isEmpty else { throw ResolverError.mediaMissing }
        return try await engine.post(
            from: candidates,
            request: request,
            page: nil,
            document: nil,
            resolverVersion: "pinterest-widget.1",
            author: pin.resolvedAuthor(),
            text: pin.description ?? ""
        )
    }
}

// MARK: - Kick

struct KickResolver: PlatformResolver {
    let platform: Platform = .kick
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .kick, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .kick }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        if let clipID = Self.clipID(in: request.canonicalURL),
           let post = try? await resolveClip(request, clipID: clipID) {
            return post
        }
        return try await engine.resolvePage(request, resolverVersion: "kick-public-page.2")
    }

    static func clipID(in url: URL) -> String? {
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "clip" })?.value, query.hasPrefix("clip_") {
            return query
        }
        if let index = url.pathComponents.firstIndex(where: { $0.hasPrefix("clip_") }) {
            return url.pathComponents[index]
        }
        return nil
    }

    /// Kick publishes clip metadata through a documented public endpoint that needs no account.
    private func resolveClip(_ request: ResolveRequest, clipID: String) async throws -> ResolvedPost {
        guard let endpoint = URL(string: "https://kick.com/api/v2/clips/\(clipID)") else { throw ResolverError.invalidURL }
        let data = try await engine.fetcher.json(at: endpoint, profile: .browser)
        let payload = try JSONDecoder().decode(KickClipResponse.self, from: data)
        guard let clip = payload.clip else { throw ResolverError.contentNotFound }
        let candidates = clip.mediaCandidates()
        guard !candidates.isEmpty else { throw ResolverError.mediaMissing }
        var warnings: [String] = []
        if clip.publishesAdaptiveStreamOnly {
            warnings.append(L10n.value("resolver.warning.adaptiveStream"))
        } else if clip.publishesNoVideoAddress {
            warnings.append(L10n.value("resolver.warning.kickNoVideo"))
        }
        return try await engine.post(
            from: candidates,
            request: request,
            page: nil,
            document: nil,
            resolverVersion: "kick-public-api.1",
            author: clip.resolvedAuthor(),
            text: clip.title ?? "",
            extraWarnings: warnings
        )
    }
}

// MARK: - YouTube

struct YouTubeResolver: PlatformResolver {
    let platform: Platform = .youTube
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .youTube, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .youTube }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        // YouTube publishes a video's title, channel, and cover through oEmbed, and publishes
        // no downloadable file address at all. Stashy archives what the source publishes and
        // states plainly that the video stream itself is not part of the capture.
        guard let videoID = Self.videoID(in: request.canonicalURL) else { throw ResolverError.invalidURL }
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let endpoint = components?.url else { throw ResolverError.invalidURL }
        let data: Data
        do {
            data = try await engine.fetcher.json(at: endpoint)
        } catch let error as ResolverError where error == .contentNotFound {
            throw ResolverError.contentPrivate
        }
        let metadata = try JSONDecoder().decode(OEmbedMetadata.self, from: data)

        var candidates: [MediaCandidate] = []
        for name in ["maxresdefault", "sddefault", "hqdefault"] {
            if let cover = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg") {
                candidates.append(MediaCandidate(url: cover, declaredType: "image/jpeg", kind: .photo, qualityLabel: "Cover image"))
            }
        }
        if let published = metadata.thumbnailURL {
            candidates.append(MediaCandidate(url: published, declaredType: "image/jpeg", kind: .photo, qualityLabel: "Cover image"))
        }
        // Only the best cover the source actually serves is kept.
        let verified = await engine.verify(candidates)
        guard let best = verified.first else { throw ResolverError.mediaMissing }
        return try await engine.post(
            from: [best],
            request: request,
            page: nil,
            document: nil,
            resolverVersion: "youtube-oembed.1",
            author: metadata.author(for: request.canonicalURL),
            text: metadata.title ?? "",
            extraWarnings: [L10n.value("resolver.warning.youTubeCoverOnly")]
        )
    }

    static func videoID(in url: URL) -> String? {
        if url.host?.lowercased().contains("youtu.be") == true {
            let identifier = url.pathComponents.dropFirst().first ?? ""
            return identifier.isEmpty ? nil : identifier
        }
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "v" })?.value, !value.isEmpty {
            return value
        }
        for marker in ["shorts", "embed", "live", "v"] {
            if let index = url.pathComponents.firstIndex(of: marker),
               url.pathComponents.index(after: index) < url.pathComponents.endIndex {
                return url.pathComponents[url.pathComponents.index(after: index)]
            }
        }
        return nil
    }
}

// MARK: - Imgur

struct ImgurResolver: PlatformResolver {
    let platform: Platform = .imgur
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .imgur, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == .imgur }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        // Imgur serves every asset from a predictable public address. Stashy checks the ones
        // the identifier implies and keeps only what the host actually serves, so a guess can
        // never turn into a broken archive.
        if let identifier = Self.assetID(in: request.canonicalURL) {
            var candidates: [MediaCandidate] = []
            for ext in ["mp4", "gif", "png", "jpeg", "jpg"] {
                guard let url = URL(string: "https://i.imgur.com/\(identifier).\(ext)") else { continue }
                candidates.append(MediaCandidate(
                    url: url,
                    declaredType: nil,
                    kind: nil,
                    qualityLabel: "Imgur original"
                ))
            }
            let verified = await engine.verify(candidates)
            if let best = verified.first {
                return try await engine.post(
                    from: [best],
                    request: request,
                    page: nil,
                    document: nil,
                    resolverVersion: "imgur-direct.1"
                )
            }
        }
        return try await engine.resolvePage(request, resolverVersion: "imgur-public-page.2")
    }

    static func assetID(in url: URL) -> String? {
        let skipped: Set<String> = ["gallery", "a", "t", "r", "user", "search"]
        let components = url.pathComponents.dropFirst().filter { !$0.isEmpty }
        guard let last = components.last, !skipped.contains(last) else { return nil }
        let identifier = last.split(separator: ".").first.map(String.init) ?? last
        let isPlausible = identifier.count >= 5 && identifier.count <= 12 && identifier.allSatisfy { $0.isLetter || $0.isNumber }
        return isPlausible ? identifier : nil
    }
}

// MARK: - Public payload models

private struct XSyndicationPost: Decodable {
    struct User: Decodable {
        let name: String?
        let screenName: String?
        let profileImageURL: String?
        enum CodingKeys: String, CodingKey {
            case name
            case screenName = "screen_name"
            case profileImageURL = "profile_image_url_https"
        }
    }

    struct VideoVariant: Decodable {
        let type: String?
        let src: String?
        let bitrate: Int?
        enum CodingKeys: String, CodingKey { case type = "content_type", src, bitrate }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try? values.decodeIfPresent(String.self, forKey: .type)
            src = try? values.decodeIfPresent(String.self, forKey: .src)
            bitrate = try? values.decodeIfPresent(Int.self, forKey: .bitrate)
        }
    }

    struct Video: Decodable {
        let variants: [VideoVariant]?
        let durationMs: Int?
        let poster: String?
        enum CodingKeys: String, CodingKey { case variants, durationMs = "durationMs", poster }
    }

    struct MediaDetail: Decodable {
        let type: String?
        let mediaURL: String?
        let originalInfo: OriginalInfo?
        let videoInfo: VideoInfo?
        let extAltText: String?

        struct OriginalInfo: Decodable {
            let width: Int?
            let height: Int?
            enum CodingKeys: String, CodingKey { case width, height }
        }

        struct VideoInfo: Decodable {
            struct Variant: Decodable {
                let contentType: String?
                let url: String?
                let bitrate: Int?
                enum CodingKeys: String, CodingKey { case contentType = "content_type", url, bitrate }
            }
            let variants: [Variant]?
            let durationMillis: Int?
            enum CodingKeys: String, CodingKey { case variants, durationMillis = "duration_millis" }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case mediaURL = "media_url_https"
            case originalInfo = "original_info"
            case videoInfo = "video_info"
            case extAltText = "ext_alt_text"
        }
    }

    let text: String?
    let createdAt: String?
    let user: User?
    let mediaDetails: [MediaDetail]?
    let photos: [Photo]?
    let video: Video?

    struct Photo: Decodable {
        let url: String?
        let width: Int?
        let height: Int?
    }

    enum CodingKeys: String, CodingKey {
        case text
        case createdAt = "created_at"
        case user
        case mediaDetails
        case photos
        case video
    }

    func resolvedAuthor() -> ResolvedAuthor {
        ResolvedAuthor(
            platformID: nil,
            displayName: user?.name ?? "X",
            username: user?.screenName,
            avatarURL: user?.profileImageURL.flatMap(URL.init(string:)),
            profileURL: user?.screenName.flatMap { URL(string: "https://x.com/\($0)") },
            badges: []
        )
    }

    /// Keeps the order the post exposes and, for a video, the highest-bitrate progressive file.
    func mediaCandidates() -> [MediaCandidate] {
        var results: [MediaCandidate] = []
        for detail in mediaDetails ?? [] {
            switch detail.type?.lowercased() {
            case "video", "animated_gif":
                let progressive = (detail.videoInfo?.variants ?? [])
                    .filter { ($0.contentType ?? "").contains("mp4") }
                    .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
                if let source = progressive?.url, let url = URL(string: source) {
                    results.append(MediaCandidate(
                        url: url,
                        declaredType: progressive?.contentType,
                        kind: detail.type?.lowercased() == "animated_gif" ? .gif : .video,
                        width: detail.originalInfo?.width,
                        height: detail.originalInfo?.height,
                        duration: detail.videoInfo?.durationMillis.map { Double($0) / 1_000 },
                        alt: detail.extAltText,
                        thumbnailURL: detail.mediaURL.flatMap(URL.init(string:)),
                        bitrate: progressive?.bitrate,
                        qualityLabel: "Best public variant"
                    ))
                }
            default:
                if let source = detail.mediaURL, let url = URL(string: source + "?name=orig") {
                    results.append(MediaCandidate(
                        url: url,
                        declaredType: nil,
                        kind: .photo,
                        width: detail.originalInfo?.width,
                        height: detail.originalInfo?.height,
                        alt: detail.extAltText,
                        qualityLabel: "Original size"
                    ))
                }
            }
        }
        guard results.isEmpty else { return results }
        for photo in photos ?? [] {
            guard let source = photo.url, let url = URL(string: source) else { continue }
            results.append(MediaCandidate(url: url, declaredType: nil, kind: .photo, width: photo.width, height: photo.height, qualityLabel: "Public photo"))
        }
        if let best = (video?.variants ?? []).filter({ ($0.type ?? "").contains("mp4") }).max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }),
           let source = best.src, let url = URL(string: source) {
            results.append(MediaCandidate(url: url, declaredType: best.type, kind: .video, bitrate: best.bitrate, qualityLabel: "Best public variant"))
        }
        return results
    }
}

private struct PinterestWidgetResponse: Decodable {
    struct Pin: Decodable {
        struct Images: Decodable {
            let original: Image?
            enum CodingKeys: String, CodingKey { case original = "orig" }
        }
        struct Image: Decodable {
            let url: String?
            let width: Int?
            let height: Int?
        }
        struct Videos: Decodable {
            let videoList: [String: Video]?
            enum CodingKeys: String, CodingKey { case videoList = "video_list" }
        }
        struct Video: Decodable {
            let url: String?
            let width: Int?
            let height: Int?
            let duration: Double?
        }
        struct Pinner: Decodable {
            let fullName: String?
            let username: String?
            let imageSmallURL: String?
            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case username
                case imageSmallURL = "image_small_url"
            }
        }

        let id: String?
        let description: String?
        let images: Images?
        let videos: Videos?
        let pinner: Pinner?
        let error: String?

        func resolvedAuthor() -> ResolvedAuthor {
            ResolvedAuthor(
                platformID: nil,
                displayName: pinner?.fullName ?? "Pinterest",
                username: pinner?.username,
                avatarURL: pinner?.imageSmallURL.flatMap(URL.init(string:)),
                profileURL: pinner?.username.flatMap { URL(string: "https://www.pinterest.com/\($0)/") },
                badges: []
            )
        }

        func mediaCandidates() -> [MediaCandidate] {
            var results: [MediaCandidate] = []
            // A video pin exposes several renditions; the largest one is the source rendition.
            if let best = videos?.videoList?.values.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }),
               let source = best.url, let url = URL(string: source) {
                results.append(MediaCandidate(
                    url: url, declaredType: nil, kind: .video,
                    width: best.width, height: best.height,
                    duration: best.duration.map { $0 / 1_000 },
                    qualityLabel: "Source rendition"
                ))
            }
            if let image = images?.original, let source = image.url, let url = URL(string: source) {
                results.append(MediaCandidate(
                    url: url, declaredType: nil, kind: nil,
                    width: image.width, height: image.height,
                    qualityLabel: "Original size", cleanliness: .original
                ))
            }
            return results
        }
    }

    let pins: [Pin]

    /// The widget endpoint answers with `data` as a bare array of pins. It has also been seen
    /// wrapping them in an object, so both shapes decode rather than one silently failing and
    /// sending every pin down the page fallback.
    private enum CodingKeys: String, CodingKey { case data }
    private struct Wrapper: Decodable { let pins: [Pin]? }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? values.decode([Pin].self, forKey: .data) {
            pins = array
        } else if let wrapped = try? values.decode(Wrapper.self, forKey: .data) {
            pins = wrapped.pins ?? []
        } else {
            pins = []
        }
    }
}

private struct KickClipResponse: Decodable {
    struct Clip: Decodable {
        struct Channel: Decodable {
            let username: String?
            let slug: String?
            let profilePicture: String?
            enum CodingKeys: String, CodingKey {
                case username, slug
                case profilePicture = "profile_picture"
            }
        }
        let title: String?
        let clipURL: String?
        let thumbnailURL: String?
        let videoURL: String?
        let duration: Double?
        let channel: Channel?

        enum CodingKeys: String, CodingKey {
            case title
            case clipURL = "clip_url"
            case thumbnailURL = "thumbnail_url"
            case videoURL = "video_url"
            case duration
            case channel
        }

        func resolvedAuthor() -> ResolvedAuthor {
            ResolvedAuthor(
                platformID: nil,
                displayName: channel?.username ?? "Kick",
                username: channel?.slug,
                avatarURL: channel?.profilePicture.flatMap(URL.init(string:)),
                profileURL: channel?.slug.flatMap { URL(string: "https://kick.com/\($0)") },
                badges: []
            )
        }

        var videoAddresses: [String] { [videoURL, clipURL].compactMap { $0 } }

        /// True when Kick published the clip only as an adaptive stream. Stashy archives files,
        /// so in that case the clip's own poster frame is what can honestly be saved.
        ///
        /// The guard matters: with no address at all, "contains" is vacuously false and this
        /// used to claim Kick had published an adaptive stream that the response never mentioned.
        var publishesAdaptiveStreamOnly: Bool {
            guard !videoAddresses.isEmpty else { return false }
            return !videoAddresses.contains { source in
                guard let url = URL(string: source) else { return false }
                return !["m3u8", "mpd"].contains(url.pathExtension.lowercased())
            }
        }

        /// The clip record listed no video address of any kind. That is a different fact from
        /// "published as a stream", and saying which one is true is the whole point.
        var publishesNoVideoAddress: Bool { videoAddresses.isEmpty }

        func mediaCandidates() -> [MediaCandidate] {
            var results: [MediaCandidate] = []
            for source in [videoURL, clipURL] {
                guard let source, let url = URL(string: source),
                      !["m3u8", "mpd"].contains(url.pathExtension.lowercased())
                else { continue }
                results.append(MediaCandidate(
                    url: url, declaredType: nil, kind: .video, duration: duration,
                    thumbnailURL: thumbnailURL.flatMap(URL.init(string:)),
                    qualityLabel: "Public clip"
                ))
            }
            if let thumbnail = thumbnailURL, let url = URL(string: thumbnail) {
                results.append(MediaCandidate(url: url, declaredType: nil, kind: .photo, qualityLabel: "Clip poster frame"))
            }
            return results
        }
    }

    let clip: Clip?
}

// MARK: - X official API models

private struct XAPIPostResponse: Decodable {
    let data: XAPIPost
    let includes: XAPIIncludes?
}

private struct XAPIPost: Decodable {
    let id: String
    let text: String
    let authorID: String?
    let createdAt: String?
    let attachments: XAPIAttachments?

    enum CodingKeys: String, CodingKey {
        case id, text, attachments
        case authorID = "author_id"
        case createdAt = "created_at"
    }
}

private struct XAPIAttachments: Decodable {
    let mediaKeys: [String]
    enum CodingKeys: String, CodingKey { case mediaKeys = "media_keys" }
}

private struct XAPIIncludes: Decodable {
    let media: [XAPIMedia]?
    let users: [XAPIUser]?
}

private struct XAPIUser: Decodable {
    let id: String
    let name: String
    let username: String?
    let profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, username
        case profileImageURL = "profile_image_url"
    }
}

private struct XAPIMedia: Decodable {
    let mediaKey: String
    let type: String
    let url: String?
    let previewImageURL: String?
    let width: Int?
    let height: Int?
    let durationMilliseconds: Double?
    let altText: String?
    let variants: [XAPIVariant]?

    enum CodingKeys: String, CodingKey {
        case type, url, width, height, variants
        case mediaKey = "media_key"
        case previewImageURL = "preview_image_url"
        case durationMilliseconds = "duration_ms"
        case altText = "alt_text"
    }

    func resolvedMedia(orderIndex: Int) -> ResolvedMedia? {
        let mediaType: MediaType
        switch type {
        case "photo": mediaType = .photo
        case "video": mediaType = .video
        case "animated_gif": mediaType = .gif
        default: return nil
        }
        let sourceVariants: [XAPIVariant]
        if let url {
            sourceVariants = [XAPIVariant(url: url, contentType: nil, bitRate: nil)]
        } else {
            sourceVariants = variants ?? []
        }
        let resolvedVariants = sourceVariants.compactMap { variant -> MediaVariant? in
            guard let url = URL(string: variant.url) else { return nil }
            return MediaVariant(
                id: UUID(), url: url, headers: [:], expirationDate: SignedURLExpiry.date(in: url),
                width: width, height: height, bitrate: variant.bitRate, fps: nil, isHDR: nil,
                codec: variant.contentType?.split(separator: "/").last.map(String.init),
                container: url.pathExtension.lowercased(), hasSeparateAudio: false,
                estimatedBytes: nil, qualityLabel: "Best source-exposed variant", cleanliness: .unknown
            )
        }
        guard !resolvedVariants.isEmpty else { return nil }
        return ResolvedMedia(
            id: UUID(), orderIndex: orderIndex, type: mediaType,
            thumbnailURL: previewImageURL.flatMap(URL.init(string:)), variants: resolvedVariants,
            width: width, height: height, duration: durationMilliseconds.map { $0 / 1_000 }, altText: altText
        )
    }
}

private struct XAPIVariant: Decodable {
    let url: String
    let contentType: String?
    let bitRate: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case contentType = "content_type"
        case bitRate = "bit_rate"
    }
}
