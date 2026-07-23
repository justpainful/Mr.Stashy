import Foundation

protocol ResolverHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionResolverHTTPClient: ResolverHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
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
        request.timeoutInterval = 15
        request.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
        request.setValue("Stashy/0.1 (local archive client)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await client.data(for: request)
        try validate(response)
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

    init(shortLinkExpander: any URLRedirectExpanding = PlatformShortLinkExpander()) {
        // Every listed public source can be inspected now, but only a `.passing` row in the
        // generated matrix authorizes a "verified" product claim. These adapters use public
        // pages and source-exposed metadata only: no cookies, private sessions, or bypasses.
        resolvers = [
            DirectMediaResolver(),
            TikTokResolver(),
            InstagramResolver(),
            XResolver(),
            PublicOpenGraphResolver(platform: .pinterest),
            PublicOpenGraphResolver(platform: .snapchat),
            PublicOpenGraphResolver(platform: .kick),
            PublicOpenGraphResolver(platform: .threads),
            PublicOpenGraphResolver(platform: .tumblr),
            PublicOpenGraphResolver(platform: .imgur),
            PublicOpenGraphResolver(platform: .youTube)
        ]
        self.shortLinkExpander = shortLinkExpander
    }

    func resolve(_ url: URL) async throws -> ResolvedPost {
        var canonical = try URLCanonicalizer.canonicalize(url)
        if !URLCanonicalizer.isDirectMedia(canonical), URLCanonicalizer.isPlatformShortLink(canonical) {
            canonical = try URLCanonicalizer.canonicalize(await shortLinkExpander.destination(for: canonical))
        }
        let request = ResolveRequest(originalURL: url, canonicalURL: canonical)
        guard let resolver = resolvers.first(where: { $0.canHandle(canonical) }) else {
            throw ResolverError.unsupportedURL
        }
        return try await resolver.resolve(request)
    }
}

struct DirectMediaResolver: PlatformResolver {
    let platform: Platform = .directMedia

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.isDirectMedia(url) }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        let type = MediaType(url: request.canonicalURL)
        let variant = MediaVariant(
            id: UUID(), url: request.canonicalURL, headers: [:], expirationDate: nil,
            width: nil, height: nil, bitrate: nil, fps: nil, isHDR: nil, codec: nil,
            container: request.canonicalURL.pathExtension.lowercased(), hasSeparateAudio: false,
            estimatedBytes: nil, qualityLabel: "Original source", cleanliness: .original
        )
        let media = ResolvedMedia(id: UUID(), orderIndex: 0, type: type, thumbnailURL: nil, variants: [variant], width: nil, height: nil, duration: nil, altText: nil)
        return ResolvedPost(
            id: UUID(), platform: .directMedia, originalURL: request.originalURL, canonicalURL: request.canonicalURL,
            author: ResolvedAuthor(platformID: nil, displayName: request.canonicalURL.host ?? "", username: nil, avatarURL: nil, profileURL: nil, badges: []),
            text: "", createdAt: nil, fetchedAt: .now, quotedPost: nil, media: [media], resolverVersion: "1.0", warnings: []
        )
    }
}

struct PublicOpenGraphResolver: PlatformResolver {
    let platform: Platform
    private let client: any ResolverHTTPClient

    init(platform: Platform, client: any ResolverHTTPClient = URLSessionResolverHTTPClient()) {
        self.platform = platform
        self.client = client
    }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == platform }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        var urlRequest = URLRequest(url: request.canonicalURL)
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Stashy/0.1 (local archive client)", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await client.data(for: urlRequest)
        try validate(http)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ResolverError.invalidResponse
        }
        let document = OpenGraphDocument(html: html)
        let media = document.media.enumerated().compactMap { index, candidate -> ResolvedMedia? in
            guard let url = URL(string: candidate.url, relativeTo: request.canonicalURL)?.absoluteURL else { return nil }
            let type = MediaType(url: url, declaredType: candidate.type)
            let variant = MediaVariant(
                id: UUID(), url: url, headers: [:], expirationDate: nil, width: candidate.width, height: candidate.height,
                bitrate: nil, fps: nil, isHDR: nil, codec: nil, container: url.pathExtension.lowercased(), hasSeparateAudio: false,
                estimatedBytes: nil, qualityLabel: "Source-exposed", cleanliness: .unknown
            )
            return ResolvedMedia(
                id: UUID(), orderIndex: index, type: type, thumbnailURL: nil,
                variants: [variant], width: candidate.width, height: candidate.height,
                duration: candidate.duration, altText: candidate.alt
            )
        }
        guard !media.isEmpty else { throw ResolverError.mediaMissing }
        return ResolvedPost(
            id: UUID(), platform: platform, originalURL: request.originalURL,
            canonicalURL: document.canonicalURL(relativeTo: request.canonicalURL) ?? request.canonicalURL,
            author: ResolvedAuthor(platformID: nil, displayName: document.siteName ?? request.canonicalURL.host ?? "", username: nil, avatarURL: nil, profileURL: nil, badges: []),
            text: document.description ?? document.title ?? "", createdAt: nil, fetchedAt: .now, quotedPost: nil,
            media: media, resolverVersion: "open-graph.1", warnings: []
        )
    }
}

struct TikTokResolver: PlatformResolver {
    let platform: Platform = .tikTok
    private let openGraph: PublicOpenGraphResolver
    private let client: any ResolverHTTPClient

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient()) {
        openGraph = PublicOpenGraphResolver(platform: .tikTok, client: client)
        self.client = client
    }

    func canHandle(_ url: URL) -> Bool { openGraph.canHandle(url) }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        var pageRequest = URLRequest(url: request.canonicalURL)
        pageRequest.timeoutInterval = 20
        pageRequest.setValue("Stashy/0.1 (local archive client)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.data(for: pageRequest)
        try validate(response)
        if let html = String(data: data, encoding: .utf8),
           let videoURL = TikTokPublicDocument.firstPlayableVideoURL(in: html, relativeTo: request.canonicalURL) {
            let variant = MediaVariant(
                id: UUID(), url: videoURL, headers: ["Referer": request.canonicalURL.absoluteString], expirationDate: nil,
                width: nil, height: nil, bitrate: nil, fps: nil, isHDR: nil, codec: nil,
                container: "mp4", hasSeparateAudio: false, estimatedBytes: nil,
                qualityLabel: "Public source", cleanliness: .unknown
            )
            let media = ResolvedMedia(
                id: UUID(), orderIndex: 0, type: .video, thumbnailURL: nil, variants: [variant],
                width: nil, height: nil, duration: nil, altText: nil
            )
            return ResolvedPost(
                id: UUID(), platform: .tikTok, originalURL: request.originalURL, canonicalURL: request.canonicalURL,
                author: ResolvedAuthor(platformID: nil, displayName: "TikTok", username: nil, avatarURL: nil, profileURL: nil, badges: []),
                text: "", createdAt: nil, fetchedAt: .now, quotedPost: nil, media: [media],
                resolverVersion: "tiktok-public-json.1", warnings: []
            )
        }
        return try await openGraph.resolve(request)
    }
}

private enum TikTokPublicDocument {
    /// TikTok's public page payload has used both escaped JSON and direct JSON string values.
    /// Read only a source-exposed playable address; no cookies, sessions, or private APIs.
    static func firstPlayableVideoURL(in html: String, relativeTo base: URL) -> URL? {
        let pattern = #"\"(?:playAddr|downloadAddr)\"\s*:\s*\"([^\"]+)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let raw = String(html[range])
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}

struct InstagramResolver: PlatformResolver {
    let platform: Platform = .instagram
    private let openGraph: PublicOpenGraphResolver

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient()) {
        openGraph = PublicOpenGraphResolver(platform: .instagram, client: client)
    }

    func canHandle(_ url: URL) -> Bool { openGraph.canHandle(url) }
    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost { try await openGraph.resolve(request) }
}

struct XResolver: PlatformResolver {
    let platform: Platform = .x
    private let openGraph: PublicOpenGraphResolver
    private let client: any ResolverHTTPClient
    private let credentials: any ResolverCredentialProvider

    init(
        client: any ResolverHTTPClient = URLSessionResolverHTTPClient(),
        credentials: any ResolverCredentialProvider = KeychainResolverCredentialProvider()
    ) {
        openGraph = PublicOpenGraphResolver(platform: .x, client: client)
        self.client = client
        self.credentials = credentials
    }

    func canHandle(_ url: URL) -> Bool { openGraph.canHandle(url) }
    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        guard let token = credentials.value(for: .xBearerToken) else {
            return try await openGraph.resolve(request)
        }
        return try await resolveViaOfficialAPI(request, token: token)
    }

    private func resolveViaOfficialAPI(_ request: ResolveRequest, token: String) async throws -> ResolvedPost {
        guard let postID = request.canonicalURL.pathComponents.drop(while: { $0 != "status" }).dropFirst().first,
              !postID.isEmpty
        else { throw ResolverError.invalidURL }
        var components = URLComponents(string: "https://api.x.com/2/tweets/\(postID)")!
        components.queryItems = [
            URLQueryItem(name: "expansions", value: "attachments.media_keys,author_id"),
            URLQueryItem(name: "tweet.fields", value: "attachments,author_id,created_at"),
            URLQueryItem(name: "media.fields", value: "alt_text,duration_ms,height,media_key,preview_image_url,type,url,variants,width"),
            URLQueryItem(name: "user.fields", value: "id,name,profile_image_url,username")
        ]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.timeoutInterval = 20
        urlRequest.setValue(token.hasPrefix("Bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.data(for: urlRequest)
        try validate(response)
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
                id: UUID(), url: url, headers: [:], expirationDate: nil,
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
            let fragment = String(html[Range(tag.range, in: html)!])
            let pairs = Self.attributePairs(in: fragment)
            guard let name = (pairs["property"] ?? pairs["name"])?.lowercased(), let content = pairs["content"] else { continue }
            values[name, default: []].append(content)
            switch name {
            case "og:image", "og:image:url":
                if seenMediaURLs.insert(content).inserted {
                    orderedMedia.append(.init(url: content, type: "image", width: nil, height: nil, duration: nil, alt: nil))
                    mostRecentImage = orderedMedia.indices.last
                }
            case "og:video", "og:video:url", "twitter:player:stream":
                if seenMediaURLs.insert(content).inserted {
                    orderedMedia.append(.init(url: content, type: "video", width: nil, height: nil, duration: nil, alt: nil))
                    mostRecentVideo = orderedMedia.indices.last
                }
            case "og:audio", "og:audio:url":
                if seenMediaURLs.insert(content).inserted {
                    orderedMedia.append(.init(url: content, type: "audio", width: nil, height: nil, duration: nil, alt: nil))
                    mostRecentAudio = orderedMedia.indices.last
                }
            case "og:image:width":
                if let mostRecentImage, let width = Int(content) { orderedMedia[mostRecentImage].width = width }
            case "og:image:height":
                if let mostRecentImage, let height = Int(content) { orderedMedia[mostRecentImage].height = height }
            case "og:image:alt":
                if let mostRecentImage { orderedMedia[mostRecentImage].alt = content }
            case "og:video:width":
                if let mostRecentVideo, let width = Int(content) { orderedMedia[mostRecentVideo].width = width }
            case "og:video:height":
                if let mostRecentVideo, let height = Int(content) { orderedMedia[mostRecentVideo].height = height }
            case "og:video:duration":
                if let mostRecentVideo, let duration = TimeInterval(content), duration >= 0 {
                    orderedMedia[mostRecentVideo].duration = duration
                }
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

    var title: String? { attributes["og:title"]?.first }
    var description: String? { attributes["og:description"]?.first ?? attributes["description"]?.first }
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

    func canonicalURL(relativeTo base: URL) -> URL? {
        attributes["og:url"]?.first.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    private static func attributePairs(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z:-]+)\s*=\s*[\"']([^\"']*)[\"']"#
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) ?? []
        return matches.reduce(into: [:]) { result, match in
            guard let keyRange = Range(match.range(at: 1), in: tag), let valueRange = Range(match.range(at: 2), in: tag) else { return }
            result[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
        }
    }
}

private extension MediaType {
    init(url: URL, declaredType: String? = nil) {
        let kind = (declaredType ?? "") + " " + url.pathExtension.lowercased()
        if kind.contains("video") || ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) { self = .video }
        else if kind.contains("audio") || ["mp3", "m4a", "wav"].contains(url.pathExtension.lowercased()) { self = .audio }
        else if kind.contains("gif") { self = .gif }
        else { self = .photo }
    }
}

private func validate(_ response: HTTPURLResponse) throws {
    switch response.statusCode {
    case 200 ... 299: break
    case 401, 403: throw ResolverError.authenticationRequired
    case 404: throw ResolverError.contentNotFound
    case 429: throw ResolverError.rateLimited
    default: throw ResolverError.networkFailure
    }
}
