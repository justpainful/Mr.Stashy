import Foundation

/// Tumblr's post page inlines the post in its own block format (NPF): every image at every
/// size it was rendered, and video files hosted on Tumblr. A person's own API key reads the
/// same structure through the public API when the page cannot be read.
struct TumblrExtractor: Extractor {
    let platform: Platform = .tumblr

    static func reference(from url: URL) -> (blog: String, id: String)? {
        let host = url.host?.lowercased() ?? ""
        let parts = LinkParser.pathComponents(url)
        if host == "www.tumblr.com" || host == "tumblr.com" {
            guard parts.count >= 2 else { return nil }
            if parts[0] == "blog", parts.count >= 4, parts[1] == "view" { return (parts[2], parts[3]) }
            guard parts[1].allSatisfy(\.isNumber) else { return nil }
            return (parts[0].replacingOccurrences(of: "@", with: ""), parts[1])
        }
        if host.hasSuffix(".tumblr.com"), let index = parts.firstIndex(where: { $0 == "post" || $0 == "image" }), parts.count > index + 1 {
            return (String(host.dropLast(".tumblr.com".count)), parts[index + 1])
        }
        return nil
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let reference = Self.reference(from: url) else { throw StashyError.unsupportedLink }
        let canonical = URL(string: "https://www.tumblr.com/\(reference.blog)/\(reference.id)")!
        let page = try await client.html(canonical, userAgent: UserAgent.desktopSafari)
        let html = page.text

        if let raw = HTMLText.script(withID: "___INITIAL_STATE___", in: html), let state = try? JSONValue.parse(raw) {
            let objects = state["PeeprRoute"]["initialTimeline"]["objects"].array
            if let postNode = objects.first(where: { $0["objectType"].string == "post" }) ?? objects.first {
                if let post = try Self.build(postNode, reference: reference, url: url, canonical: canonical, extractor: "tumblr-page.1") { return post }
            }
            // The page's own API token reads the post when the timeline did not include it.
            if let token = state["apiFetchStore"]["API_TOKEN"].string {
                if let post = try await Self.fromAPI(reference: reference, url: url, canonical: canonical, token: token, client: client) { return post }
            }
        }
        if let key = credentials.value(for: .tumblrAPIKey), !key.isEmpty {
            var components = URLComponents(string: "https://api.tumblr.com/v2/blog/\(reference.blog)/posts/\(reference.id)")!
            components.queryItems = [.init(name: "api_key", value: key), .init(name: "npf", value: "true")]
            if let root = try? await client.json(components.url!, userAgent: UserAgent.stashy), let post = try Self.build(root["response"], reference: reference, url: url, canonical: canonical, extractor: "tumblr-api.1") {
                return post
            }
        }
        // Last: the page's metadata plus any Tumblr media addresses it renders.
        let graph = Extract.openGraphItems(html: html, base: canonical)
        var items = graph.items
        for address in Set(HTMLText.allGroups(#"(https://[0-9a-z.]*media\.tumblr\.com/[^"'\s<>]+?\.(?:mp4|gif|png|jpe?g|pnj))"#, in: html)) {
            guard let mediaURL = URL(string: address), !items.contains(where: { $0.best?.delivery.primaryURL == mediaURL }) else { continue }
            let ext = mediaURL.pathExtension.lowercased()
            items.append(Extract.item(ext == "mp4" ? .video : ext == "gif" ? .gif : .photo, [ext == "mp4" ? Extract.video(mediaURL, label: "page") : Extract.photo(mediaURL, label: "page")]))
        }
        guard !items.isEmpty else {
            throw html.contains("This Tumblr may contain sensitive media") || html.contains("log in") ? StashyError.loginRequired : StashyError.noMedia
        }
        return Post(platform: .tumblr, sourceURL: url, canonicalURL: canonical, author: Author(name: reference.blog, handle: reference.blog, profileURL: URL(string: "https://www.tumblr.com/\(reference.blog)")), title: graph.title, text: graph.description ?? "", createdAt: nil, items: items, notes: [L10n.value("note.previewOnly")], extractor: "tumblr-page-scan.1")
    }

    private static func fromAPI(reference: (blog: String, id: String), url: URL, canonical: URL, token: String, client: HTTPClient) async throws -> Post? {
        let endpoint = URL(string: "https://www.tumblr.com/api/v2/blog/\(reference.blog)/posts/\(reference.id)?npf=true")!
        guard let root = try? await client.json(endpoint, userAgent: UserAgent.desktopSafari, headers: ["Authorization": "Bearer \(token)", "Referer": canonical.absoluteString]) else { return nil }
        return try build(root["response"], reference: reference, url: url, canonical: canonical, extractor: "tumblr-web-api.1")
    }

    private static func build(_ post: JSONValue, reference: (blog: String, id: String), url: URL, canonical: URL, extractor: String) throws -> Post? {
        guard post.exists else { return nil }
        var items: [MediaItem] = []
        var paragraphs: [String] = []
        // A reblog carries the original blocks in its trail; the post's own blocks come after.
        var blockGroups: [[JSONValue]] = post["trail"].array.map { $0["content"].array }
        blockGroups.append(post["content"].array)
        for blocks in blockGroups {
            for block in blocks {
                switch block["type"].string {
                case "image":
                    let media = block["media"].array
                    let variants = media.compactMap { rendition -> MediaVariant? in
                        guard let mediaURL = rendition["url"].url else { return nil }
                        var variant = Extract.photo(mediaURL, width: rendition["width"].int, height: rendition["height"].int, label: rendition["hasOriginalDimensions"].bool == true || rendition["has_original_dimensions"].bool == true ? "original" : "rendition")
                        if let type = rendition["type"].string { variant.codec = type.replacingOccurrences(of: "image/", with: "").uppercased(); variant.container = type.contains("png") ? "png" : type.contains("gif") ? "gif" : type.contains("webp") ? "webp" : "jpg" }
                        return variant
                    }
                    guard !variants.isEmpty else { continue }
                    let isGIF = variants.contains { $0.container == "gif" }
                    items.append(Extract.item(isGIF ? .gif : .photo, variants, alt: block["altText"].string ?? block["alt_text"].string))
                case "video":
                    let media = block["media"]
                    guard let mediaURL = media["url"].url ?? block["url"].url else { continue }
                    let poster = block["poster"].array.first?["url"].url
                    if mediaURL.host?.contains("tumblr.com") == true || mediaURL.pathExtension.lowercased() == "mp4" {
                        items.append(Extract.item(.video, [Extract.video(mediaURL, width: media["width"].int, height: media["height"].int, label: "video")], thumbnail: poster))
                    } else if let poster {
                        // An embedded YouTube or Vimeo player: keep its poster and say so.
                        items.append(Extract.item(.photo, [Extract.photo(poster, label: "poster")], alt: block["provider"].string))
                    }
                case "audio":
                    if let mediaURL = block["media"]["url"].url {
                        items.append(Extract.item(.audio, [MediaVariant(delivery: .file(mediaURL), codec: "AAC", container: mediaURL.pathExtension.isEmpty ? "mp3" : mediaURL.pathExtension, label: "audio")], thumbnail: block["poster"].array.first?["url"].url, alt: block["title"].string))
                    }
                case "text":
                    if let text = block["text"].string, !text.isEmpty { paragraphs.append(text) }
                default:
                    continue
                }
            }
        }
        guard !items.isEmpty else { return nil }
        let blogName = post["blogName"].string ?? post["blog_name"].string ?? reference.blog
        let blog = post["blog"]
        let author = Author(
            name: blog["title"].string ?? blog["name"].string ?? blogName,
            handle: blogName,
            avatarURL: blog["avatar"].array.first?["url"].url ?? URL(string: "https://api.tumblr.com/v2/blog/\(blogName)/avatar/512"),
            profileURL: URL(string: "https://www.tumblr.com/\(blogName)")
        )
        let text = paragraphs.joined(separator: "\n\n")
        return Post(platform: .tumblr, sourceURL: url, canonicalURL: canonical, author: author, title: post["summary"].string.flatMap { text.isEmpty ? $0 : nil }, text: text, createdAt: Extract.date(fromUnix: post["timestamp"].double), items: items, extractor: extractor)
    }
}
