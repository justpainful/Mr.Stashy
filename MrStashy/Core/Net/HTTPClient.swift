import Foundation

/// The request identity Stashy presents to a source. Most sources answer a phone's Safari with
/// the app-install page and the desktop browser with the actual post, so each extractor picks.
enum UserAgent {
    static let desktopSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
    static let desktopChrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let iPhoneSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
    static let stashy = "Stashy/1.0 (iOS; +https://github.com/justpainful/Mr.Stashy)"
}

struct HTTPResponse: Sendable {
    var data: Data
    var status: Int
    var headers: [String: String]
    var finalURL: URL

    var text: String { String(decoding: data, as: UTF8.self) }
    var contentType: String { headers["content-type"]?.lowercased() ?? "" }
    var contentLength: Int64? { headers["content-length"].flatMap { Int64($0) } }

    func json() throws -> JSONValue {
        do { return try JSONValue.parse(data) } catch { throw StashyError.sourceChanged }
    }
}

protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> HTTPResponse
}

struct URLSessionTransport: HTTPTransport {
    static let shared = URLSessionTransport()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9,ar;q=0.8"]
        return URLSession(configuration: configuration)
    }()

    func perform(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StashyError.network }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return HTTPResponse(data: data, status: http.statusCode, headers: headers, finalURL: http.url ?? request.url!)
    }
}

/// Thin convenience layer every extractor uses. It never adds credentials on its own.
struct HTTPClient: Sendable {
    var transport: any HTTPTransport = URLSessionTransport.shared

    func get(_ url: URL, userAgent: String = UserAgent.desktopSafari, headers: [String: String] = [:], accept: String = "*/*") async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await transport.perform(request)
    }

    func post(_ url: URL, body: Data, contentType: String, userAgent: String = UserAgent.desktopSafari, headers: [String: String] = [:]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await transport.perform(request)
    }

    func postJSON(_ url: URL, json: [String: Any], userAgent: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await post(url, body: body, contentType: "application/json", userAgent: userAgent, headers: headers)
    }

    func postForm(_ url: URL, fields: [String: String], userAgent: String = UserAgent.desktopSafari, headers: [String: String] = [:]) async throws -> HTTPResponse {
        let body = fields.map { key, value in "\(Self.formEncode(key))=\(Self.formEncode(value))" }.joined(separator: "&")
        return try await post(url, body: Data(body.utf8), contentType: "application/x-www-form-urlencoded", userAgent: userAgent, headers: headers)
    }

    /// Fetches a page and returns its HTML, following the status code into a meaningful error.
    func html(_ url: URL, userAgent: String = UserAgent.desktopSafari, headers: [String: String] = [:]) async throws -> HTTPResponse {
        let response = try await get(url, userAgent: userAgent, headers: headers, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        try Self.check(response)
        return response
    }

    func json(_ url: URL, userAgent: String = UserAgent.desktopSafari, headers: [String: String] = [:]) async throws -> JSONValue {
        let response = try await get(url, userAgent: userAgent, headers: headers, accept: "application/json,*/*;q=0.5")
        try Self.check(response)
        return try response.json()
    }

    /// Resolves a short link to its destination without downloading the page body.
    func expand(_ url: URL, userAgent: String = UserAgent.iPhoneSafari) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let response = try await transport.perform(request)
        return response.finalURL
    }

    /// A ranged probe that tells whether an address serves media without downloading it.
    func probe(_ url: URL, headers: [String: String] = [:], userAgent: String = UserAgent.desktopSafari) async -> (contentType: String, length: Int64?, finalURL: URL)? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-255", forHTTPHeaderField: "Range")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let response = try? await transport.perform(request), (200 ... 299).contains(response.status) else { return nil }
        let type = response.contentType
        var length = response.contentLength
        if let range = response.headers["content-range"], let total = range.split(separator: "/").last, let value = Int64(total) {
            length = value
        }
        return (type, length, response.finalURL)
    }

    static func check(_ response: HTTPResponse) throws {
        switch response.status {
        case 200 ... 299: return
        case 401, 403: throw StashyError.loginRequired
        case 404, 410: throw StashyError.notFound
        case 429: throw StashyError.rateLimited
        case 451: throw StashyError.blocked
        default: throw StashyError.network
        }
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - HTML helpers

enum HTMLText {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "#39": "'", "#x27": "'", "#x2F": "/", "#47": "/"
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var scanner = text[...]
        while let amp = scanner.firstIndex(of: "&") {
            result += scanner[..<amp]
            scanner = scanner[amp...]
            guard let semi = scanner.firstIndex(of: ";"), scanner.distance(from: scanner.startIndex, to: semi) <= 10 else {
                result += "&"
                scanner = scanner.dropFirst()
                continue
            }
            let entity = String(scanner[scanner.index(after: scanner.startIndex) ..< semi])
            if let replacement = named[entity] {
                result += replacement
            } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else {
                result += "&\(entity);"
            }
            scanner = scanner[scanner.index(after: semi)...]
        }
        result += scanner
        return result
    }

    /// Strips tags and collapses whitespace; enough for captions, never for layout.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decode(text)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<meta property="og:video" content="…">` and friends, in document order, decoded.
    static func metaTags(in html: String) -> [(name: String, content: String)] {
        let pattern = #"<meta\s+[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            let attributes = attributePairs(in: tag)
            guard let name = attributes["property"] ?? attributes["name"] ?? attributes["itemprop"], let content = attributes["content"] else { return nil }
            return (name.lowercased(), decode(content))
        }
    }

    static func attributePairs(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let keyRange = Range(match.range(at: 1), in: tag) else { continue }
            let value = Range(match.range(at: 2), in: tag).map { String(tag[$0]) } ?? Range(match.range(at: 3), in: tag).map { String(tag[$0]) } ?? ""
            let key = String(tag[keyRange]).lowercased()
            if result[key] == nil { result[key] = value }
        }
        return result
    }

    /// The body of `<script id="…">…</script>` (or `type="application/json"` with a marker).
    static func script(withID id: String, in html: String) -> String? {
        let pattern = "<script[^>]*id=[\"']\(NSRegularExpression.escapedPattern(for: id))[\"'][^>]*>(.*?)</script>"
        return firstGroup(pattern, in: html, options: [.dotMatchesLineSeparators, .caseInsensitive])
    }

    static func firstGroup(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }

    static func allGroups(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let group = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[group])
        }
    }

    /// Extracts every balanced JSON object that starts at an occurrence of `marker`, e.g.
    /// `"video_versions":[` — returns the text from the opening bracket to its match.
    static func balancedJSON(after marker: String, in text: String, limit: Int = 50) -> [String] {
        var results: [String] = []
        var searchRange = text.startIndex ..< text.endIndex
        while results.count < limit, let found = text.range(of: marker, range: searchRange) {
            var index = found.upperBound
            while index < text.endIndex, text[index] == " " || text[index] == ":" { index = text.index(after: index) }
            guard index < text.endIndex, text[index] == "{" || text[index] == "[" else {
                searchRange = found.upperBound ..< text.endIndex
                continue
            }
            if let end = balancedEnd(from: index, in: text) {
                results.append(String(text[index ... end]))
                searchRange = text.index(after: end) ..< text.endIndex
            } else {
                break
            }
        }
        return results
    }

    static func balancedEnd(from start: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
