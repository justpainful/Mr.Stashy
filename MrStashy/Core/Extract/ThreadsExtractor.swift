import Foundation

/// Threads serves a signed-out reader the post page with the thread's data inlined in its
/// script blobs; the embed page carries the same node. Both are read before giving up.
struct ThreadsExtractor: Extractor {
    let platform: Platform = .threads

    private static let headers = ["User-Agent": UserAgent.desktopChrome, "Referer": "https://www.threads.com/"]

    static func code(from url: URL) -> String? {
        let parts = LinkParser.pathComponents(url)
        guard let index = parts.firstIndex(of: "post"), parts.count > index + 1 else { return nil }
        return parts[index + 1]
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let code = Self.code(from: url) else { throw StashyError.unsupportedLink }
        let handle = LinkParser.pathComponents(url).first.flatMap { $0.hasPrefix("@") ? String($0.dropFirst()) : nil }
        let pageURL = URL(string: "https://www.threads.com/@\(handle ?? "threads")/post/\(code)")!
        var failures: [StashyError] = []
        for candidate in [pageURL, pageURL.appendingPathComponent("embed")] {
            do {
                let page = try await client.html(candidate, userAgent: UserAgent.desktopChrome, headers: ["Sec-Fetch-Mode": "navigate"])
                if let post = try parse(page.text, code: code, url: url, canonical: pageURL) { return post }
                failures.append(.loginRequired)
            } catch let error as StashyError {
                failures.append(error)
            } catch {
                failures.append(StashyError.from(error))
            }
        }
        let priority: [StashyError] = [.notFound, .rateLimited, .noMedia, .loginRequired, .network, .sourceChanged]
        throw priority.first { failures.contains($0) } ?? .loginRequired
    }

    private func parse(_ html: String, code: String, url: URL, canonical: URL) throws -> Post? {
        // Every inlined `thread_items` array, from any script blob on the page.
        for raw in HTMLText.balancedJSON(after: "\"thread_items\"", in: html, limit: 40) {
            guard let list = try? JSONValue.parse(raw) else { continue }
            for entry in list.array {
                let post = entry["post"]
                guard post["code"].string == code else { continue }
                if let built = build(post, code: code, url: url, canonical: canonical) { return built }
            }
        }
        // Threads also publishes link-preview tags for public posts.
        let graph = Extract.openGraphItems(html: html, base: canonical)
        let items = graph.items.filter { !($0.best?.delivery.primaryURL.path.contains("/static/") ?? true) }
        if !items.isEmpty {
            let handle = HTMLText.firstGroup(#"\(@([A-Za-z0-9_.]+)\)"#, in: graph.title ?? "")
            let author = Author(name: handle ?? "", handle: handle, avatarURL: nil, profileURL: handle.flatMap { URL(string: "https://www.threads.com/@\($0)") })
            return Post(platform: .threads, sourceURL: url, canonicalURL: canonical, author: author, title: nil, text: graph.description ?? "", createdAt: nil, items: items, notes: [L10n.value("note.previewOnly")], extractor: "threads-opengraph.1")
        }
        return nil
    }

    private func build(_ post: JSONValue, code: String, url: URL, canonical: URL) -> Post? {
        var items: [MediaItem] = []
        let carousel = post["carousel_media"].array
        for node in carousel.isEmpty ? [post] : carousel {
            if let item = Self.mediaItem(from: node) { items.append(item) }
        }
        guard !items.isEmpty else { return nil }
        let user = post["user"]
        let author = Author(
            name: user["full_name"].string ?? user["username"].string ?? "",
            handle: user["username"].string,
            avatarURL: user["profile_pic_url"].url,
            profileURL: user["username"].string.flatMap { URL(string: "https://www.threads.com/@\($0)") },
            isVerified: user["is_verified"].bool ?? false
        )
        return Post(
            platform: .threads, sourceURL: url, canonicalURL: canonical, author: author, title: nil,
            text: post["caption"]["text"].string ?? "", createdAt: Extract.date(fromUnix: post["taken_at"].double),
            items: items, extractor: "threads-page.1"
        )
    }

    /// Shared with Instagram's app-shaped payloads: `video_versions` and `image_versions2`.
    static func mediaItem(from node: JSONValue) -> MediaItem? {
        let width = node["original_width"].int
        let height = node["original_height"].int
        let videos = node["video_versions"].array.compactMap { version -> MediaVariant? in
            guard let versionURL = version["url"].url else { return nil }
            return Extract.video(versionURL, width: version["width"].int ?? width, height: version["height"].int ?? height, label: "type \(version["type"].int ?? 0)", headers: headers)
        }
        let images = node["image_versions2"]["candidates"].array.compactMap { candidate -> MediaVariant? in
            guard let imageURL = candidate["url"].url else { return nil }
            return Extract.photo(imageURL, width: candidate["width"].int, height: candidate["height"].int, label: "candidate", headers: headers)
        }
        if !videos.isEmpty {
            return Extract.item(.video, videos, thumbnail: images.first?.delivery.primaryURL, duration: node["video_duration"].double, alt: node["accessibility_caption"].string)
        }
        if !images.isEmpty {
            // Candidates repeat the same picture at several sizes; keep them as one item.
            return Extract.item(.photo, images, alt: node["accessibility_caption"].string)
        }
        return nil
    }
}
