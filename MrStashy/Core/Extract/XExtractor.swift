import Foundation

/// X publishes every public post through the endpoint that powers its embedded tweets. It
/// lists photos at original size and every MP4 rendition of a video. A person's own API
/// bearer token, when added, is used instead and also reaches age-gated public posts.
struct XExtractor: Extractor {
    let platform: Platform = .x

    static func postID(from url: URL) -> String? {
        let parts = LinkParser.pathComponents(url)
        guard let index = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }), parts.count > index + 1 else { return nil }
        let id = parts[index + 1].prefix { $0.isNumber }
        return id.isEmpty ? nil : String(id)
    }

    /// The embed player's request token: `((id / 1e15) * π).toString(36)` without zeros or the
    /// point, exactly as the widget computes it.
    static func token(for id: String) -> String {
        guard let value = Double(id) else { return "" }
        let number = (value / 1e15) * Double.pi
        var integer = UInt64(number)
        var fraction = number - Double(integer)
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var integerPart = ""
        if integer == 0 { integerPart = "0" }
        while integer > 0 {
            integerPart = String(digits[Int(integer % 36)]) + integerPart
            integer /= 36
        }
        var fractionPart = ""
        var delta = 0.5 * (number.nextUp - number)
        delta = max(Double.leastNonzeroMagnitude, delta)
        if fraction >= delta {
            repeat {
                fraction *= 36
                delta *= 36
                let digit = Int(fraction)
                fractionPart.append(digits[digit])
                fraction -= Double(digit)
                if fraction > 0.5 || (fraction == 0.5 && (digit & 1) == 1) {
                    if fraction + delta > 1 {
                        // Round up, propagating carries through the generated digits.
                        var chars = Array(fractionPart)
                        var position = chars.count - 1
                        while position >= 0 {
                            let current = digits.firstIndex(of: chars[position]) ?? 0
                            if current + 1 < 36 {
                                chars[position] = digits[current + 1]
                                break
                            }
                            chars[position] = "0"
                            position -= 1
                        }
                        fractionPart = String(chars)
                        break
                    }
                }
            } while fraction >= delta
        }
        let joined = integerPart + "." + fractionPart
        return joined.replacingOccurrences(of: "0", with: "").replacingOccurrences(of: ".", with: "")
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let id = Self.postID(from: url) else { throw StashyError.unsupportedLink }
        if let bearer = credentials.value(for: .xBearerToken), !bearer.isEmpty {
            if let post = try? await fromOfficialAPI(id: id, url: url, client: client, bearer: bearer) { return post }
        }
        return try await fromSyndication(id: id, url: url, client: client)
    }

    // MARK: Embed endpoint

    private func fromSyndication(id: String, url: URL, client: HTTPClient) async throws -> Post {
        var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        components.queryItems = [.init(name: "id", value: id), .init(name: "token", value: Self.token(for: id)), .init(name: "lang", value: "en")]
        let response = try await client.get(components.url!, userAgent: UserAgent.desktopChrome, headers: ["Referer": "https://platform.twitter.com/"], accept: "application/json")
        switch response.status {
        case 200: break
        case 404: throw StashyError.notFound
        case 429: throw StashyError.rateLimited
        default: throw StashyError.network
        }
        guard !response.data.isEmpty, response.contentType.contains("json") else { throw StashyError.notFound }
        let root = try response.json()
        if root["__typename"].string == "TweetTombstone" {
            let tombstone = root["tombstone"]["text"]["text"].string?.lowercased() ?? ""
            throw tombstone.contains("age") || tombstone.contains("sensitive") ? StashyError.loginRequired : StashyError.privateContent
        }
        var items: [MediaItem] = []
        for detail in root["mediaDetails"].array {
            if let item = Self.item(fromMediaDetail: detail) { items.append(item) }
        }
        if items.isEmpty {
            for photo in root["photos"].array {
                guard let photoURL = photo["url"].url else { continue }
                items.append(Extract.item(.photo, [Extract.photo(Self.original(photoURL), width: photo["width"].int, height: photo["height"].int, label: "orig")], alt: photo["accessibilityLabel"].string))
            }
        }
        // A quoted post's media is part of what the person sees; keep it after the post's own.
        for detail in root["quoted_tweet"]["mediaDetails"].array {
            if let item = Self.item(fromMediaDetail: detail) { items.append(item) }
        }
        let user = root["user"]
        let author = Author(
            name: user["name"].string ?? "",
            handle: user["screen_name"].string,
            avatarURL: user["profile_image_url_https"].url.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "_normal", with: "")) },
            profileURL: user["screen_name"].string.flatMap { URL(string: "https://x.com/\($0)") },
            isVerified: user["is_blue_verified"].bool ?? user["verified"].bool ?? false
        )
        var text = root["text"].string ?? ""
        if let range = root["display_text_range"].array.map(\.int).compactMap({ $0 }).last, range < text.count {
            // The trailing media link is not part of what the person wrote.
            text = String(text.prefix(range))
        }
        return Post(
            platform: .x, sourceURL: url, canonicalURL: URL(string: "https://x.com/\(author.handle ?? "i")/status/\(id)")!,
            author: author, title: nil, text: text, createdAt: Extract.date(fromISO: root["created_at"].string),
            items: items, extractor: "x-syndication.1"
        )
    }

    private static func item(fromMediaDetail detail: JSONValue) -> MediaItem? {
        let type = detail["type"].string ?? "photo"
        let width = detail["original_info"]["width"].int
        let height = detail["original_info"]["height"].int
        let alt = detail["ext_alt_text"].string
        switch type {
        case "video", "animated_gif":
            let variants = detail["video_info"]["variants"].array.compactMap { variant -> MediaVariant? in
                guard variant["content_type"].string == "video/mp4", let variantURL = variant["url"].url else { return nil }
                let dimensions = HTMLText.firstGroup(#"/(\d+x\d+)/"#, in: variantURL.path)?.split(separator: "x").compactMap { Int($0) }
                return Extract.video(variantURL, width: dimensions?.first ?? width, height: dimensions?.last ?? height, bitrate: variant["bitrate"].int, label: dimensions.map { "\($0[0])×\($0[1])" } ?? "mp4")
            }
            guard !variants.isEmpty else { return nil }
            let duration = detail["video_info"]["duration_millis"].double.map { $0 / 1000 }
            return Extract.item(type == "animated_gif" ? .gif : .video, variants, thumbnail: detail["media_url_https"].url, duration: duration, alt: alt)
        default:
            guard let photoURL = detail["media_url_https"].url else { return nil }
            return Extract.item(.photo, [Extract.photo(original(photoURL), width: width, height: height, label: "orig")], alt: alt)
        }
    }

    /// `pbs.twimg.com/media/ID.jpg` serves a downsized default; `?name=orig` is the upload.
    private static func original(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let ext = url.pathExtension
        if !ext.isEmpty {
            components.path = String(components.path.dropLast(ext.count + 1))
            components.queryItems = [.init(name: "format", value: ext), .init(name: "name", value: "orig")]
        } else {
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "name" } + [.init(name: "name", value: "orig")]
        }
        return components.url ?? url
    }

    // MARK: Official API (person's own bearer token)

    private func fromOfficialAPI(id: String, url: URL, client: HTTPClient, bearer: String) async throws -> Post {
        var components = URLComponents(string: "https://api.x.com/2/tweets/\(id)")!
        components.queryItems = [
            .init(name: "expansions", value: "attachments.media_keys,author_id"),
            .init(name: "media.fields", value: "url,variants,width,height,type,duration_ms,preview_image_url,alt_text"),
            .init(name: "tweet.fields", value: "created_at,text"),
            .init(name: "user.fields", value: "name,username,profile_image_url,verified")
        ]
        let token = bearer.hasPrefix("Bearer ") ? bearer : "Bearer \(bearer)"
        let root = try await client.json(components.url!, userAgent: UserAgent.stashy, headers: ["Authorization": token])
        let tweet = root["data"]
        guard tweet.exists else { throw StashyError.notFound }
        var items: [MediaItem] = []
        for media in root["includes"]["media"].array {
            switch media["type"].string {
            case "photo":
                guard let photoURL = media["url"].url else { continue }
                items.append(Extract.item(.photo, [Extract.photo(Self.original(photoURL), width: media["width"].int, height: media["height"].int, label: "orig")], alt: media["alt_text"].string))
            case "video", "animated_gif":
                let variants = media["variants"].array.compactMap { variant -> MediaVariant? in
                    guard variant["content_type"].string == "video/mp4", let variantURL = variant["url"].url else { return nil }
                    return Extract.video(variantURL, width: media["width"].int, height: media["height"].int, bitrate: variant["bit_rate"].int, label: "mp4")
                }
                guard !variants.isEmpty else { continue }
                items.append(Extract.item(media["type"].string == "animated_gif" ? .gif : .video, variants, thumbnail: media["preview_image_url"].url, duration: media["duration_ms"].double.map { $0 / 1000 }, alt: media["alt_text"].string))
            default: continue
            }
        }
        let user = root["includes"]["users"].array.first ?? .null
        let author = Author(name: user["name"].string ?? "", handle: user["username"].string, avatarURL: user["profile_image_url"].url, profileURL: user["username"].string.flatMap { URL(string: "https://x.com/\($0)") }, isVerified: user["verified"].bool ?? false)
        return Post(platform: .x, sourceURL: url, canonicalURL: URL(string: "https://x.com/\(author.handle ?? "i")/status/\(id)")!, author: author, title: nil, text: tweet["text"].string ?? "", createdAt: Extract.date(fromISO: tweet["created_at"].string), items: items, extractor: "x-api-v2.1")
    }
}
