import Foundation

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

    init() {
        // A resolver is registered only after its public-source contract is verified. Keeping
        // experimental Open Graph parsing out of this list prevents the product from implying
        // support for a platform that has not passed the live release gate.
        resolvers = [DirectMediaResolver()]
    }

    func resolve(_ url: URL) async throws -> ResolvedPost {
        let canonical = try URLCanonicalizer.canonicalize(url)
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

    init(platform: Platform) { self.platform = platform }

    func canHandle(_ url: URL) -> Bool { URLCanonicalizer.platform(for: url) == platform }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedPost {
        var urlRequest = URLRequest(url: request.canonicalURL)
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Stashy/0.1 (local archive client)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ResolverError.invalidResponse }
        switch http.statusCode {
        case 200 ... 299: break
        case 401, 403: throw ResolverError.authenticationRequired
        case 404: throw ResolverError.contentNotFound
        case 429: throw ResolverError.rateLimited
        default: throw ResolverError.networkFailure
        }
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
            return ResolvedMedia(id: UUID(), orderIndex: index, type: type, thumbnailURL: nil, variants: [variant], width: candidate.width, height: candidate.height, duration: nil, altText: candidate.alt)
        }
        return ResolvedPost(
            id: UUID(), platform: platform, originalURL: request.originalURL,
            canonicalURL: document.canonicalURL(relativeTo: request.canonicalURL) ?? request.canonicalURL,
            author: ResolvedAuthor(platformID: nil, displayName: document.siteName ?? request.canonicalURL.host ?? "", username: nil, avatarURL: nil, profileURL: nil, badges: []),
            text: document.description ?? document.title ?? "", createdAt: nil, fetchedAt: .now, quotedPost: nil,
            media: media, resolverVersion: "1.0", warnings: media.isEmpty ? [String(localized: "resolver.warning.noMediaExposed")] : []
        )
    }
}

struct OpenGraphCandidate {
    var url: String
    var type: String?
    var width: Int?
    var height: Int?
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
        for tag in tags {
            let fragment = String(html[Range(tag.range, in: html)!])
            let pairs = Self.attributePairs(in: fragment)
            guard let name = (pairs["property"] ?? pairs["name"])?.lowercased(), let content = pairs["content"] else { continue }
            values[name, default: []].append(content)
            let type: String?
            switch name {
            case "og:image", "og:image:url": type = "image"
            case "og:video", "og:video:url": type = "video"
            default: type = nil
            }
            if let type, seenMediaURLs.insert(content).inserted {
                orderedMedia.append(.init(url: content, type: type, width: nil, height: nil, alt: nil))
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
        let videos = attributes["og:video"] ?? attributes["og:video:url"] ?? []
        let images = attributes["og:image"] ?? attributes["og:image:url"] ?? []
        let videoItems = videos.map { OpenGraphCandidate(url: $0, type: "video", width: nil, height: nil, alt: nil) }
        let imageItems = images.map { OpenGraphCandidate(url: $0, type: "image", width: nil, height: nil, alt: nil) }
        return imageItems + videoItems
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
