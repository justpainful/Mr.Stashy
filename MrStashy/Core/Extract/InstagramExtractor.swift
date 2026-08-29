import Foundation

/// Instagram for a signed-out reader. Three public surfaces are tried: the web app's own
/// GraphQL post query, the embed page, and finally the post page's link-preview metadata.
/// Stories and private accounts need a session Stashy never holds, and say so.
struct InstagramExtractor: Extractor {
    let platform: Platform = .instagram

    private static let appID = "936619743392459"
    private static let postQueryDocID = "8845758582119845"
    private static let headers = ["User-Agent": UserAgent.desktopChrome, "Referer": "https://www.instagram.com/"]

    static func shortcode(from url: URL) -> String? {
        let parts = LinkParser.pathComponents(url)
        guard let index = parts.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }), parts.count > index + 1 else { return nil }
        let code = parts[index + 1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return code.unicodeScalars.allSatisfy { allowed.contains($0) } && code.count >= 5 ? code : nil
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        let parts = LinkParser.pathComponents(url)
        if parts.first == "stories" { throw StashyError.loginRequired }
        guard let code = Self.shortcode(from: url) else { throw StashyError.unsupportedLink }
        var failures: [StashyError] = []
        for step in [fromGraphQL, fromEmbed, fromPage] {
            do {
                return try await step(code, url, client)
            } catch let error as StashyError {
                failures.append(error)
            } catch {
                failures.append(StashyError.from(error))
            }
        }
        let priority: [StashyError] = [.privateContent, .notFound, .rateLimited, .loginRequired, .noMedia, .network, .sourceChanged]
        throw priority.first { failures.contains($0) } ?? .loginRequired
    }

    // MARK: GraphQL

    private func fromGraphQL(code: String, url: URL, client: HTTPClient) async throws -> Post {
        let variables = "{\"shortcode\":\"\(code)\",\"fetch_tagged_user_count\":null,\"hoisted_comment_id\":null,\"hoisted_reply_id\":null}"
        let response = try await client.postForm(
            URL(string: "https://www.instagram.com/graphql/query")!,
            fields: ["variables": variables, "doc_id": Self.postQueryDocID, "lsd": "AVqbxe3J_YA", "server_timestamps": "true"],
            userAgent: UserAgent.desktopChrome,
            headers: ["X-IG-App-ID": Self.appID, "X-FB-LSD": "AVqbxe3J_YA", "X-ASBD-ID": "129477", "Origin": "https://www.instagram.com", "Referer": "https://www.instagram.com/p/\(code)/", "Sec-Fetch-Site": "same-origin"]
        )
        if response.status == 429 { throw StashyError.rateLimited }
        guard response.status == 200, response.contentType.contains("json") else { throw StashyError.loginRequired }
        let root = try response.json()
        let media = root["data"]["xdt_shortcode_media"]
        guard media.exists else {
            if root["data"].exists { throw StashyError.notFound }
            throw StashyError.loginRequired
        }
        return try build(media, code: code, url: url, extractor: "instagram-graphql.1")
    }

    private func build(_ media: JSONValue, code: String, url: URL, extractor: String) throws -> Post {
        var items: [MediaItem] = []
        let children = media["edge_sidecar_to_children"]["edges"].array.map { $0["node"] }
        for node in children.isEmpty ? [media] : children {
            if let item = mediaItem(from: node) { items.append(item) }
        }
        guard !items.isEmpty else { throw StashyError.noMedia }
        let owner = media["owner"]
        let author = Author(
            name: owner["full_name"].string ?? owner["username"].string ?? "",
            handle: owner["username"].string,
            avatarURL: owner["profile_pic_url"].url,
            profileURL: owner["username"].string.flatMap { URL(string: "https://www.instagram.com/\($0)/") },
            isVerified: owner["is_verified"].bool ?? false
        )
        let caption = media["edge_media_to_caption"]["edges"].array.first?["node"]["text"].string ?? ""
        return Post(
            platform: .instagram, sourceURL: url, canonicalURL: URL(string: "https://www.instagram.com/p/\(code)/")!,
            author: author, title: nil, text: caption, createdAt: Extract.date(fromUnix: media["taken_at_timestamp"].double),
            items: items, extractor: extractor
        )
    }

    private func mediaItem(from node: JSONValue) -> MediaItem? {
        let width = node["dimensions"]["width"].int
        let height = node["dimensions"]["height"].int
        let alt = node["accessibility_caption"].string
        if node["is_video"].bool == true, let videoURL = node["video_url"].url {
            var variants = [Extract.video(videoURL, width: width, height: height, label: "video_url", headers: Self.headers)]
            // Newer payloads carry the full ladder.
            for version in node["video_versions"].array {
                guard let versionURL = version["url"].url else { continue }
                variants.append(Extract.video(versionURL, width: version["width"].int, height: version["height"].int, label: "type \(version["type"].int ?? 0)", headers: Self.headers))
            }
            return Extract.item(.video, variants, thumbnail: node["display_url"].url, duration: node["video_duration"].double, alt: alt)
        }
        var variants: [MediaVariant] = []
        for resource in node["display_resources"].array {
            guard let src = resource["src"].url else { continue }
            variants.append(Extract.photo(src, width: resource["config_width"].int, height: resource["config_height"].int, label: "display_resources", headers: Self.headers))
        }
        for candidate in node["image_versions2"]["candidates"].array {
            guard let src = candidate["url"].url else { continue }
            variants.append(Extract.photo(src, width: candidate["width"].int, height: candidate["height"].int, label: "image_versions2", headers: Self.headers))
        }
        if variants.isEmpty, let display = node["display_url"].url {
            variants.append(Extract.photo(display, width: width, height: height, label: "display_url", headers: Self.headers))
        }
        guard !variants.isEmpty else { return nil }
        return Extract.item(.photo, variants, alt: alt)
    }

    // MARK: Embed page

    private func fromEmbed(code: String, url: URL, client: HTTPClient) async throws -> Post {
        let embedURL = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")!
        let page = try await client.html(embedURL, userAgent: UserAgent.desktopChrome)
        let html = page.text
        // The embed inlines the same GraphQL node when it has it.
        if let raw = HTMLText.balancedJSON(after: "\"shortcode_media\"", in: html).first, let media = try? JSONValue.parse(raw), media.exists {
            return try build(media, code: code, url: url, extractor: "instagram-embed.json.1")
        }
        if let raw = HTMLText.balancedJSON(after: "\"xdt_shortcode_media\"", in: html).first, let media = try? JSONValue.parse(raw), media.exists {
            return try build(media, code: code, url: url, extractor: "instagram-embed.json.1")
        }
        var items: [MediaItem] = []
        if let videoURL = HTMLText.firstGroup(#""video_url":"([^"]+)""#, in: html).flatMap({ URL(string: $0.replacingOccurrences(of: "\\u0026", with: "&").replacingOccurrences(of: "\\/", with: "/")) }) {
            items.append(Extract.item(.video, [Extract.video(videoURL, label: "embed", headers: Self.headers)]))
        }
        if let imageTag = HTMLText.firstGroup(#"(<img[^>]+class="EmbeddedMediaImage"[^>]*>)"#, in: html), let src = HTMLText.attributePairs(in: imageTag)["src"], let imageURL = URL(string: HTMLText.decode(src)) {
            items.append(Extract.item(.photo, [Extract.photo(imageURL, label: "embed", headers: Self.headers)], alt: HTMLText.attributePairs(in: imageTag)["alt"]))
        }
        guard !items.isEmpty else {
            throw html.lowercased().contains("login") || html.contains("Sorry, this page isn't available") ? StashyError.loginRequired : StashyError.noMedia
        }
        let handle = HTMLText.firstGroup(#"class="UsernameText">([^<]+)<"#, in: html) ?? HTMLText.firstGroup(#""username":"([^"]+)""#, in: html)
        let caption = HTMLText.firstGroup(#"<div class="Caption">(.*?)</div>"#, in: html, options: [.dotMatchesLineSeparators]).map(HTMLText.plain) ?? ""
        let author = Author(name: handle ?? "", handle: handle, avatarURL: nil, profileURL: handle.flatMap { URL(string: "https://www.instagram.com/\($0)/") })
        return Post(platform: .instagram, sourceURL: url, canonicalURL: URL(string: "https://www.instagram.com/p/\(code)/")!, author: author, title: nil, text: caption, createdAt: nil, items: items, notes: [L10n.value("note.instagramEmbed")], extractor: "instagram-embed.html.1")
    }

    // MARK: Post page metadata

    private func fromPage(code: String, url: URL, client: HTTPClient) async throws -> Post {
        let pageURL = URL(string: "https://www.instagram.com/p/\(code)/")!
        let page = try await client.html(pageURL, userAgent: UserAgent.desktopChrome)
        let graph = Extract.openGraphItems(html: page.text, base: pageURL)
        let items = graph.items.filter { item in
            guard let first = item.best?.delivery.primaryURL else { return false }
            return !first.path.contains("/static/") && !first.host!.contains("facebook.com")
        }
        guard !items.isEmpty else { throw StashyError.loginRequired }
        let handle = HTMLText.firstGroup(#"\(@([A-Za-z0-9_.]+)\)"#, in: graph.title ?? "")
        let author = Author(name: graph.title?.components(separatedBy: " on Instagram").first ?? handle ?? "", handle: handle, avatarURL: nil, profileURL: handle.flatMap { URL(string: "https://www.instagram.com/\($0)/") })
        return Post(platform: .instagram, sourceURL: url, canonicalURL: pageURL, author: author, title: nil, text: graph.description ?? "", createdAt: nil, items: items, notes: [L10n.value("note.previewOnly")], extractor: "instagram-opengraph.1")
    }
}
