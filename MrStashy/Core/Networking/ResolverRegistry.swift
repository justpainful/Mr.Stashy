import Foundation

protocol ResolverHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionResolverHTTPClient: ResolverHTTPClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResolverError.invalidResponse }
        return (data, http)
    }
}

protocol URLRedirectExpanding: Sendable {
    func destination(for url: URL) async throws -> URL
}

/// Expands only a recognized platform short link. The request is range-limited because this
/// step needs the final URL, not a full page or media download. `URLSession` follows normal
/// HTTPS redirects and exposes the final source URL on the HTTP response.
struct PlatformShortLinkExpander: URLRedirectExpanding {
    private let client: any ResolverHTTPClient

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient()) {
        self.client = client
    }

    func destination(for url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
        request.applyProfile(.browser, timeout: 15)
        let (_, response) = try await client.data(for: request)
        try ResolverResponseValidator.validate(response)
        guard let destination = response.url else { throw ResolverError.invalidResponse }
        return destination
    }
}

protocol ResolverCredentialProvider: Sendable {
    func value(for credential: ResolverCredential) -> String?
}

struct KeychainResolverCredentialProvider: ResolverCredentialProvider {
    func value(for credential: ResolverCredential) -> String? {
        KeychainStore.resolverCredential(for: credential)
    }
}

protocol PlatformResolver: Sendable {
    var platform: Platform { get }
    func canHandle(_ url: URL) -> Bool
    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost
}

struct ResolveRequest: Sendable {
    var originalURL: URL
    var canonicalURL: URL
}

struct ResolverRegistry: Sendable {
    private let resolvers: [any PlatformResolver]
    private let shortLinkExpander: any URLRedirectExpanding

    init(
        shortLinkExpander: any URLRedirectExpanding = PlatformShortLinkExpander(),
        client: any ResolverHTTPClient = URLSessionResolverHTTPClient(),
        prober: (any MediaProbing)? = nil
    ) {
        // Production resolvers confirm every candidate address actually serves media before the
        // app offers it as savable. These adapters read public pages and the source's own
        // published metadata endpoints only: no cookies, private sessions, or bypasses.
        let mediaProber = prober ?? URLSessionMediaProber(client: client)
        resolvers = [
            DirectMediaResolver(prober: mediaProber),
            TikTokResolver(client: client, prober: mediaProber),
            InstagramResolver(client: client, prober: mediaProber),
            XResolver(client: client, prober: mediaProber),
            RedditResolver(client: client, prober: mediaProber),
            BlueskyResolver(client: client, prober: mediaProber),
            PinterestResolver(client: client, prober: mediaProber),
            KickResolver(client: client, prober: mediaProber),
            YouTubeResolver(client: client, prober: mediaProber),
            ImgurResolver(client: client, prober: mediaProber),
            PublicOpenGraphResolver(platform: .snapchat, client: client, prober: mediaProber),
            // Threads answers a signed-out reader with a login page, not an empty post.
            PublicOpenGraphResolver(platform: .threads, client: client, prober: mediaProber, emptyResultError: .authenticationRequired),
            TumblrResolver(client: client, prober: mediaProber),
            // Last: a public page on a source with no dedicated adapter can still publish its
            // media the ordinary way, and a blog or news post should not be refused outright.
            GenericPageResolver(client: client, prober: mediaProber)
        ]
        self.shortLinkExpander = shortLinkExpander
    }

    /// The adapter that claims an address, or `nil` when none does. Exposed so a test can hold
    /// the advertised source list and the shipped adapters to the same standard.
    func resolver(for url: URL) -> (any PlatformResolver)? {
        resolvers.first { $0.canHandle(url) }
    }

    func resolve(_ url: URL) async throws -> ResolvedPost {
        var canonical = try URLCanonicalizer.canonicalize(url)
        if !URLCanonicalizer.isDirectMedia(canonical), URLCanonicalizer.isPlatformShortLink(canonical) {
            canonical = try URLCanonicalizer.canonicalize(await shortLinkExpander.destination(for: canonical))
        }
        let request = ResolveRequest(originalURL: url, canonicalURL: canonical)
        guard let resolver = resolver(for: canonical) else { throw ResolverError.unsupportedURL }
        return try await resolver.resolve(request)
    }
}

// MARK: - Shared resolution pipeline

/// The work every page-based adapter shares: fetch with the profile that actually returns the
/// page's published metadata, read every way the page can expose media, confirm the addresses
/// serve media, and build an ordered post.
struct PageResolutionEngine: Sendable {
    let platform: Platform
    let client: any ResolverHTTPClient
    let prober: any MediaProbing
    /// Probing costs one short request per candidate, so a page that lists many is capped.
    static let candidateLimit = 12

    var fetcher: PageFetcher { PageFetcher(client: client) }

    func resolvePage(
        _ request: ResolveRequest,
        profiles: [FetchProfile] = FetchProfile.pageOrder,
        resolverVersion: String,
        extraHeaders: [String: String] = [:]
    ) async throws -> ResolvedPost {
        let page = try await fetcher.firstUsablePage(at: request.canonicalURL, profiles: profiles) { candidatePage in
            !PageMediaExtractor.candidates(in: candidatePage.html, baseURL: candidatePage.url).isEmpty
        }
        var candidates = PageMediaExtractor.candidates(in: page.html, baseURL: page.url)
        if !extraHeaders.isEmpty {
            candidates = candidates.map { candidate in
                var copy = candidate
                copy.headers.merge(extraHeaders) { existing, _ in existing }
                return copy
            }
        }
        if candidates.isEmpty {
            if let wall = AccessWallDetector.wall(in: page, requested: request.canonicalURL) { throw wall }
            throw ResolverError.mediaMissing
        }
        let document = OpenGraphDocument(html: page.html)
        return try await post(
            from: candidates,
            request: request,
            page: page,
            document: document,
            resolverVersion: resolverVersion
        )
    }

    func post(
        from candidates: [MediaCandidate],
        request: ResolveRequest,
        page: FetchedPage?,
        document: OpenGraphDocument?,
        resolverVersion: String,
        author: ResolvedAuthor? = nil,
        text: String? = nil,
        createdAt: Date? = nil,
        extraWarnings: [String] = []
    ) async throws -> ResolvedPost {
        var warnings = extraWarnings
        var usable = candidates

        // A page that only published its own share card or logo has not exposed the post.
        let specific = usable.filter { !PageMediaExtractor.isGenericBranding($0.url) }
        if !specific.isEmpty, specific.count < usable.count {
            usable = specific
        } else if specific.isEmpty, !usable.isEmpty {
            warnings.append(L10n.value("resolver.warning.brandingOnly"))
        }

        if usable.count > Self.candidateLimit {
            warnings.append(L10n.format("resolver.warning.candidateLimit", Int64(Self.candidateLimit)))
            usable = Array(usable.prefix(Self.candidateLimit))
        }

        let verified = await verify(usable)
        if verified.isEmpty {
            // Expiry is checked first: the page told us plainly that its addresses went stale,
            // which is more specific than anything the wall heuristic can infer.
            if usable.contains(where: { SignedURLExpiry.date(in: $0.url).map { $0 < .now } == true }) {
                throw ResolverError.expiredMediaURL
            }
            if let page, let wall = AccessWallDetector.wall(in: page, requested: request.canonicalURL) { throw wall }
            throw ResolverError.mediaMissing
        }
        if verified.count < usable.count {
            warnings.append(L10n.format("resolver.warning.partialMedia", Int64(verified.count), Int64(usable.count)))
        }

        let media = verified.enumerated().map { index, candidate in
            resolvedMedia(from: candidate, orderIndex: index)
        }
        let resolvedAuthor = author ?? ResolvedAuthor(
            platformID: nil,
            displayName: document?.siteName ?? request.canonicalURL.host ?? L10n.value(platform.titleKey),
            username: nil,
            avatarURL: nil,
            profileURL: nil,
            badges: []
        )
        let canonical = document?.canonicalURL(relativeTo: request.canonicalURL) ?? request.canonicalURL
        return ResolvedPost(
            id: UUID(),
            platform: platform,
            originalURL: request.originalURL,
            canonicalURL: canonical,
            author: resolvedAuthor,
            text: text ?? document?.description ?? document?.title ?? "",
            createdAt: createdAt,
            fetchedAt: .now,
            quotedPost: nil,
            media: media,
            resolverVersion: resolverVersion,
            warnings: warnings
        )
    }

    /// Confirms candidates concurrently and keeps the source's own order. A candidate the
    /// prober rejects is dropped here rather than becoming a failed download later.
    func verify(_ candidates: [MediaCandidate]) async -> [MediaCandidate] {
        guard !candidates.isEmpty else { return [] }
        let prober = self.prober
        let results = await withTaskGroup(of: (Int, MediaCandidate?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let probe = await prober.probe(candidate.url, headers: candidate.headers, referer: nil)
                    guard let probe else { return (index, nil) }
                    var confirmed = candidate
                    confirmed.url = probe.url
                    // The server's own Content-Type is more trustworthy than a file extension,
                    // and its length is what finally gives the queue a real size and ETA.
                    if let kind = probe.mediaType { confirmed.kind = kind }
                    if let contentType = probe.contentType { confirmed.declaredType = contentType }
                    if let length = probe.contentLength, length > 0 { confirmed.estimatedBytes = length }
                    return (index, confirmed)
                }
            }
            var collected: [(Int, MediaCandidate?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        return results
            .sorted { $0.0 < $1.0 }
            .compactMap(\.1)
    }

    func resolvedMedia(from candidate: MediaCandidate, orderIndex: Int) -> ResolvedMedia {
        let type = candidate.resolvedType
        let variant = MediaVariant(
            id: UUID(),
            url: candidate.url,
            headers: candidate.headers,
            expirationDate: SignedURLExpiry.date(in: candidate.url),
            width: candidate.width,
            height: candidate.height,
            bitrate: candidate.bitrate,
            fps: nil,
            isHDR: nil,
            codec: candidate.declaredType?.split(separator: "/").last.map(String.init),
            container: candidate.url.pathExtension.lowercased(),
            hasSeparateAudio: false,
            estimatedBytes: candidate.estimatedBytes,
            qualityLabel: candidate.qualityLabel,
            cleanliness: candidate.cleanliness
        )
        return ResolvedMedia(
            id: UUID(),
            orderIndex: orderIndex,
            type: type,
            thumbnailURL: candidate.thumbnailURL,
            variants: [variant],
            width: candidate.width,
            height: candidate.height,
            duration: candidate.duration,
            altText: candidate.alt
        )
    }
}

// MARK: - Direct media

struct DirectMediaResolver: PlatformResolver {
    let platform: Platform = .directMedia
    private let prober: any MediaProbing

    init(prober: any MediaProbing = PassthroughMediaProber()) {
        self.prober = prober
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.isDirectMedia(url) }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        let probe = await prober.probe(request.canonicalURL, headers: [:], referer: nil)
        let type = probe?.mediaType ?? MediaType(candidateURL: request.canonicalURL)
        let variant = MediaVariant(
            id: UUID(), url: probe?.url ?? request.canonicalURL, headers: [:],
            expirationDate: SignedURLExpiry.date(in: request.canonicalURL),
            width: nil, height: nil, bitrate: nil, fps: nil, isHDR: nil,
            codec: probe?.contentType?.split(separator: "/").last.map(String.init),
            container: request.canonicalURL.pathExtension.lowercased(), hasSeparateAudio: false,
            estimatedBytes: probe?.contentLength, qualityLabel: "Original source", cleanliness: .original
        )
        let media = ResolvedMedia(id: UUID(), orderIndex: 0, type: type, thumbnailURL: nil, variants: [variant], width: nil, height: nil, duration: nil, altText: nil)
        return ResolvedPost(
            id: UUID(), platform: .directMedia, originalURL: request.originalURL, canonicalURL: request.canonicalURL,
            author: ResolvedAuthor(platformID: nil, displayName: request.canonicalURL.host ?? "", username: nil, avatarURL: nil, profileURL: nil, badges: []),
            text: "", createdAt: nil, fetchedAt: .now, quotedPost: nil, media: [media], resolverVersion: "direct-media.2", warnings: []
        )
    }
}

// MARK: - Public page adapter

struct PublicOpenGraphResolver: PlatformResolver {
    let platform: Platform
    private let engine: PageResolutionEngine
    /// What an empty result means for this source. A source that answers signed-out readers
    /// with a login shell publishes no metadata at all, and blaming the post for that reads as
    /// "this post has no media" when the truth is "you are not signed in".
    private let emptyResultError: ResolverError

    init(
        platform: Platform,
        client: any ResolverHTTPClient = URLSessionResolverHTTPClient(),
        prober: any MediaProbing = PassthroughMediaProber(),
        emptyResultError: ResolverError = .mediaMissing
    ) {
        self.platform = platform
        self.emptyResultError = emptyResultError
        engine = PageResolutionEngine(platform: platform, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == platform }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        do {
            // The resolver version names the source, so an archive can say which adapter wrote
            // it rather than recording the same anonymous string for three different platforms.
            var post = try await engine.resolvePage(request, resolverVersion: "\(platform.rawValue)-public-page.3")
            // These sources publish a share card for a signed-out reader, not the post's media.
            // A single still where the post held a video is a preview, and the capture has to
            // say so — the honest sentence existed only in the support screen, which is not
            // where the person is standing when they decide to save.
            if Self.isPreviewOnly(post) {
                post.warnings.append(L10n.value("resolver.warning.previewOnly"))
            }
            return post
        } catch let error as ResolverError where error == .mediaMissing {
            throw emptyResultError
        }
    }

    /// A capture that kept exactly one still image is, for these sources, the page's preview
    /// card. A video, an animation, or several items means the page published the post itself.
    private static func isPreviewOnly(_ post: ResolvedPost) -> Bool {
        post.media.count == 1 && post.media.allSatisfy { $0.type == .photo }
    }
}

/// Used for a public address on a source Stashy has no dedicated adapter for. It reads only
/// what the page publishes, which is often enough for a blog, news post, or self-hosted page.
struct GenericPageResolver: PlatformResolver {
    let platform: Platform = .directMedia
    private let engine: PageResolutionEngine

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient(), prober: any MediaProbing = PassthroughMediaProber()) {
        engine = PageResolutionEngine(platform: .directMedia, client: client, prober: prober)
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == nil }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        try await engine.resolvePage(request, resolverVersion: "public-page.generic.1")
    }
}

// MARK: - Open Graph document

struct OpenGraphCandidate {
    var url: String
    var type: String?
    var width: Int?
    var height: Int?
    var duration: TimeInterval?
    var alt: String?
}

struct OpenGraphDocument {
    let attributes: [String: [String]]
    private let orderedMediaCandidates: [OpenGraphCandidate]

    init(html: String) {
        let tagPattern = #"<meta\s+[^>]*>"#
        let tags = (try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]))?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
        var values: [String: [String]] = [:]
        var orderedMedia: [OpenGraphCandidate] = []
        var seenMediaURLs = Set<String>()
        var mostRecentImage: Int?
        var mostRecentVideo: Int?
        var mostRecentAudio: Int?
        for tag in tags {
            guard let tagRange = Range(tag.range, in: html) else { continue }
            let fragment = String(html[tagRange])
            let pairs = Self.attributePairs(in: fragment)
            guard let name = (pairs["property"] ?? pairs["name"] ?? pairs["itemprop"])?.lowercased(),
                  let rawContent = pairs["content"]
            else { continue }
            // Entity-encoded query strings are the usual cause of a signed CDN address that
            // resolves to a dead link, so every value is decoded once, here.
            let content = HTMLEntity.decode(rawContent)
            values[name, default: []].append(content)
            switch name {
            case "og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src":
                if seenMediaURLs.insert(content).inserted {
                    orderedMedia.append(.init(url: content, type: "image", width: nil, height: nil, duration: nil, alt: nil))
                    mostRecentImage = orderedMedia.indices.last
                }
            case "og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream":
                if seenMediaURLs.insert(content).inserted {
                    orderedMedia.append(.init(url: content, type: "video", width: nil, height: nil, duration: nil, alt: nil))
                    mostRecentVideo = orderedMedia.indices.last
                }
            case "og:audio", "og:audio:url", "og:audio:secure_url":
                if seenMediaURLs.insert(content).inserted {
                    orderedMedia.append(.init(url: content, type: "audio", width: nil, height: nil, duration: nil, alt: nil))
                    mostRecentAudio = orderedMedia.indices.last
                }
            case "og:image:width":
                if let mostRecentImage, let width = Int(content) { orderedMedia[mostRecentImage].width = width }
            case "og:image:height":
                if let mostRecentImage, let height = Int(content) { orderedMedia[mostRecentImage].height = height }
            case "og:image:alt", "twitter:image:alt":
                if let mostRecentImage { orderedMedia[mostRecentImage].alt = content }
            case "og:image:type":
                // A declared MIME type is what tells a player page apart from a real file.
                if let mostRecentImage { orderedMedia[mostRecentImage].type = content }
            case "og:video:width":
                if let mostRecentVideo, let width = Int(content) { orderedMedia[mostRecentVideo].width = width }
            case "og:video:height":
                if let mostRecentVideo, let height = Int(content) { orderedMedia[mostRecentVideo].height = height }
            case "og:video:type", "twitter:player:stream:content_type":
                if let mostRecentVideo { orderedMedia[mostRecentVideo].type = content }
            case "og:video:duration", "video:duration":
                if let mostRecentVideo, let duration = TimeInterval(content), duration >= 0 {
                    orderedMedia[mostRecentVideo].duration = duration
                }
            case "og:audio:type":
                if let mostRecentAudio { orderedMedia[mostRecentAudio].type = content }
            case "og:audio:duration":
                if let mostRecentAudio, let duration = TimeInterval(content), duration >= 0 {
                    orderedMedia[mostRecentAudio].duration = duration
                }
            default:
                break
            }
        }
        attributes = values
        orderedMediaCandidates = orderedMedia
    }

    var title: String? { attributes["og:title"]?.first ?? attributes["twitter:title"]?.first }
    var description: String? {
        attributes["og:description"]?.first ?? attributes["twitter:description"]?.first ?? attributes["description"]?.first
    }
    var siteName: String? { attributes["og:site_name"]?.first }

    var media: [OpenGraphCandidate] {
        if !orderedMediaCandidates.isEmpty { return orderedMediaCandidates }
        let audios = attributes["og:audio"] ?? attributes["og:audio:url"] ?? []
        let videos = attributes["og:video"] ?? attributes["og:video:url"] ?? attributes["twitter:player:stream"] ?? []
        let images = attributes["og:image"] ?? attributes["og:image:url"] ?? attributes["twitter:image"] ?? []
        let audioItems = audios.map { OpenGraphCandidate(url: $0, type: "audio", width: nil, height: nil, duration: nil, alt: nil) }
        let videoItems = videos.map { OpenGraphCandidate(url: $0, type: "video", width: nil, height: nil, duration: nil, alt: nil) }
        let imageItems = images.map { OpenGraphCandidate(url: $0, type: "image", width: nil, height: nil, duration: nil, alt: nil) }
        return audioItems + videoItems + imageItems
    }

    func candidates(relativeTo base: URL) -> [MediaCandidate] {
        media.compactMap { candidate in
            guard let url = URL(string: candidate.url, relativeTo: base)?.absoluteURL else { return nil }
            return MediaCandidate(
                url: url,
                declaredType: candidate.type,
                kind: nil,
                width: candidate.width,
                height: candidate.height,
                duration: candidate.duration,
                alt: candidate.alt,
                qualityLabel: "Source-exposed"
            )
        }
    }

    func canonicalURL(relativeTo base: URL) -> URL? {
        attributes["og:url"]?.first.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    private static func attributePairs(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z:_-]+)\s*=\s*[\"']([^\"']*)[\"']"#
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) ?? []
        return matches.reduce(into: [:]) { result, match in
            guard let keyRange = Range(match.range(at: 1), in: tag), let valueRange = Range(match.range(at: 2), in: tag) else { return }
            let key = String(tag[keyRange]).lowercased()
            // The first occurrence wins so a repeated attribute cannot silently replace the one
            // the document actually meant.
            if result[key] == nil { result[key] = String(tag[valueRange]) }
        }
    }
}
