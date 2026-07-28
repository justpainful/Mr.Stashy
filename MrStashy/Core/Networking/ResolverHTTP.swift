import Foundation

/// How Stashy identifies itself for one specific public fetch.
///
/// Open Graph, oEmbed and JSON-LD exist so a link-preview crawler can read the metadata a page
/// already publishes, and the large platforms only render that metadata when the request looks
/// like a preview crawler. A few render their post payload only for a browser. Stashy therefore
/// picks the profile that makes a public page return what it already publishes and retries with
/// the next profile when the first comes back without media. No profile sends cookies, stored
/// credentials, or private-session headers, and no profile is used until the person using the app
/// has explicitly asked Stashy to inspect that link.
enum FetchProfile: String, CaseIterable, Sendable {
    /// The link-preview crawler identity that Open Graph is designed for.
    case metadataCrawler
    /// A plain browser identity, for pages that only render their post payload to browsers.
    case browser
    /// Stashy's own identity, used for direct media hosts and Stashy-authored API calls.
    case archiveClient

    var userAgent: String {
        switch self {
        case .metadataCrawler:
            "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
        case .browser:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        case .archiveClient:
            "Stashy/1.0 (local archive client)"
        }
    }

    var accept: String {
        switch self {
        case .metadataCrawler, .browser: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        case .archiveClient: "*/*"
        }
    }

    /// Page profiles, in the order that recovers the most public metadata across the supported
    /// sources. The crawler profile is first because it is the one Open Graph is published for.
    static let pageOrder: [FetchProfile] = [.metadataCrawler, .browser, .archiveClient]
}

extension URLRequest {
    /// Applies one fetch profile. Existing header values set by a resolver always win, so a
    /// platform adapter can still send the exact `Accept` or `Referer` its API documents.
    mutating func applyProfile(_ profile: FetchProfile, timeout: TimeInterval = 20) {
        timeoutInterval = timeout
        if value(forHTTPHeaderField: "User-Agent") == nil {
            setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if value(forHTTPHeaderField: "Accept") == nil {
            setValue(profile.accept, forHTTPHeaderField: "Accept")
        }
        if value(forHTTPHeaderField: "Accept-Language") == nil {
            setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
    }
}

// MARK: - Page fetching

struct FetchedPage: Sendable {
    var url: URL
    var html: String
    var profile: FetchProfile
}

/// Fetches a public page and decodes its bytes to text, retrying across fetch profiles until an
/// extractor is satisfied. Retrying is what makes the difference between a source that "returns
/// 200 with nothing usable" and one that returns the metadata it publishes.
struct PageFetcher: Sendable {
    private let client: any ResolverHTTPClient

    init(client: any ResolverHTTPClient) {
        self.client = client
    }

    /// Fetches `url` once per profile until `isUsable` accepts the decoded body.
    /// Returns the first accepted page, or the last successfully decoded page when none was
    /// accepted, so a caller can still report a precise error instead of a generic failure.
    func firstUsablePage(
        at url: URL,
        profiles: [FetchProfile] = FetchProfile.pageOrder,
        referer: URL? = nil,
        isUsable: (FetchedPage) -> Bool
    ) async throws -> FetchedPage {
        var lastDecoded: FetchedPage?
        var lastError: Error?
        for profile in profiles {
            do {
                let page = try await self.page(at: url, profile: profile, referer: referer)
                if isUsable(page) { return page }
                lastDecoded = page
            } catch {
                lastError = error
            }
        }
        if let lastDecoded { return lastDecoded }
        throw lastError ?? ResolverError.networkFailure
    }

    func page(at url: URL, profile: FetchProfile, referer: URL? = nil) async throws -> FetchedPage {
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        request.applyProfile(profile)
        let (data, response) = try await client.data(for: request)
        try ResolverResponseValidator.validate(response)
        guard let html = HTMLTextDecoder.text(from: data, response: response) else {
            throw ResolverError.invalidResponse
        }
        return FetchedPage(url: response.url ?? url, html: html, profile: profile)
    }

    /// Fetches a Stashy-authored public API endpoint. These are documented, unauthenticated
    /// endpoints published by the source itself, so they are requested as Stashy.
    func json(at url: URL, headers: [String: String] = [:], profile: FetchProfile = .archiveClient) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.applyProfile(profile)
        let (data, response) = try await client.data(for: request)
        try ResolverResponseValidator.validate(response)
        return data
    }
}

/// Decodes page bytes using the charset the response or document declares, then falls back
/// through the encodings real pages actually use. Returning `nil` only when nothing decodes
/// prevents a legible page from being reported as an unexpected response.
enum HTMLTextDecoder {
    static func text(from data: Data, response: HTTPURLResponse?) -> String? {
        guard !data.isEmpty else { return nil }
        var encodings: [String.Encoding] = []
        if let declared = charset(in: response?.value(forHTTPHeaderField: "Content-Type")) {
            encodings.append(declared)
        }
        // A prefix decode is enough to read a <meta charset> declaration.
        let prefix = String(decoding: data.prefix(4_096), as: UTF8.self)
        if let embedded = charset(in: prefix) { encodings.append(embedded) }
        encodings.append(contentsOf: [.utf8, .isoLatin1, .windowsCP1252, .utf16])
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty { return text }
        }
        // Lossy UTF-8 keeps a mostly-valid document readable rather than discarding it.
        let lossy = String(decoding: data, as: UTF8.self)
        return lossy.isEmpty ? nil : lossy
    }

    private static func charset(in value: String?) -> String.Encoding? {
        guard let value,
              let range = value.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let token = value[range]
            .split(separator: "=", maxSplits: 1).last?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            .lowercased() ?? ""
        switch token {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1", "iso8859-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "utf-16", "utf16": return .utf16
        default:
            // Anything else, including the Arabic code pages, is resolved through the system's
            // own IANA charset table rather than a hand-written list that will fall behind.
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(token as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
    }
}

// MARK: - Media probing

struct MediaProbeResult: Sendable {
    var url: URL
    var contentType: String?
    var contentLength: Int64?

    var isPlayableMedia: Bool {
        guard let contentType = contentType?.lowercased() else { return true }
        // An adaptive-stream manifest is a playlist, not a file. Accepting one here would put a
        // few kilobytes of text into the archive under the name of the video.
        if contentType.contains("mpegurl") || contentType.contains("dash+xml") { return false }
        if contentType.hasPrefix("image/") || contentType.hasPrefix("video/") || contentType.hasPrefix("audio/") { return true }
        if contentType.contains("octet-stream") || contentType.contains("binary") { return true }
        return false
    }

    var mediaType: MediaType? {
        guard let contentType = contentType?.lowercased() else { return nil }
        if contentType.contains("image/gif") { return .gif }
        if contentType.hasPrefix("image/") { return .photo }
        if contentType.hasPrefix("video/") { return .video }
        if contentType.hasPrefix("audio/") { return .audio }
        return nil
    }
}

/// Confirms a candidate address actually serves media before Stashy offers it as savable.
/// Without this step a source that answers `200 text/html` to a media address makes the app
/// look like it succeeded and then hands the user an archive containing an error page.
protocol MediaProbing: Sendable {
    func probe(_ url: URL, headers: [String: String], referer: URL?) async -> MediaProbeResult?
}

/// Used by unit tests and by resolvers built from a fixture: accepts every candidate so tests
/// stay deterministic and offline. Production resolvers are built with `URLSessionMediaProber`.
struct PassthroughMediaProber: MediaProbing {
    func probe(_ url: URL, headers: [String: String], referer: URL?) async -> MediaProbeResult? {
        MediaProbeResult(url: url, contentType: nil, contentLength: nil)
    }
}

/// Reads only the first bytes of a candidate. Many media hosts reject `HEAD`, so this asks for a
/// short byte range instead, which is cheap and works on the hosts that matter.
struct URLSessionMediaProber: MediaProbing {
    private let client: any ResolverHTTPClient

    init(client: any ResolverHTTPClient = URLSessionResolverHTTPClient()) {
        self.client = client
    }

    func probe(_ url: URL, headers: [String: String], referer: URL?) async -> MediaProbeResult? {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let referer, request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.applyProfile(.browser, timeout: 12)
        guard let (data, response) = try? await client.data(for: request) else { return nil }
        guard (200 ... 299).contains(response.statusCode) else { return nil }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let result = MediaProbeResult(url: response.url ?? url, contentType: contentType, contentLength: totalLength(of: response))
        guard result.isPlayableMedia, !looksLikeMarkup(data) else { return nil }
        return result
    }

    /// `Content-Range: bytes 0-1023/5242880` carries the full size; `Content-Length` on a ranged
    /// response only describes the slice that was returned.
    private func totalLength(of response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let value = Int64(total) {
            return value
        }
        guard response.statusCode != 206 else { return nil }
        return response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    }

    private func looksLikeMarkup(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.hasPrefix("{") || head.hasPrefix("<?xml")
    }
}

// MARK: - Shared response validation

enum ResolverResponseValidator {
    static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200 ... 299: return
        case 401, 403: throw ResolverError.authenticationRequired
        case 404, 410: throw ResolverError.contentNotFound
        case 429: throw ResolverError.rateLimited
        default: throw ResolverError.networkFailure
        }
    }
}

// MARK: - Text helpers

enum HTMLEntity {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "#39": "'", "#x27": "'", "#x2F": "/", "#47": "/", "hellip": "…", "mdash": "—", "ndash": "–"
    ]

    /// Decodes the entity forms that actually appear in Open Graph `content` attributes.
    static func decode(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        var iterator = value.startIndex
        while iterator < value.endIndex {
            let character = value[iterator]
            guard character == "&",
                  let semicolon = value[iterator...].firstIndex(of: ";"),
                  value.distance(from: iterator, to: semicolon) <= 10
            else {
                result.append(character)
                iterator = value.index(after: iterator)
                continue
            }
            let entity = String(value[value.index(after: iterator) ..< semicolon])
            if let replacement = named[entity] {
                result.append(replacement)
            } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
                      let scalarValue = UInt32(entity.dropFirst(2), radix: 16),
                      let scalar = Unicode.Scalar(scalarValue) {
                result.append(Character(scalar))
            } else if entity.hasPrefix("#"),
                      let scalarValue = UInt32(entity.dropFirst()),
                      let scalar = Unicode.Scalar(scalarValue) {
                result.append(Character(scalar))
            } else {
                result.append("&")
                result.append(contentsOf: entity)
                result.append(";")
            }
            iterator = value.index(after: semicolon)
        }
        return result
    }
}

enum JSONStringEscape {
    /// Unescapes the slash and ampersand forms that platforms embed in inline JSON payloads.
    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u002f", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003D", with: "=")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}
