import Foundation

/// A direct file address, or any other public page: what it publishes for link previews,
/// its `<video>` sources, and its JSON-LD media objects.
struct WebExtractor: Extractor {
    let platform: Platform = .web

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        if LinkParser.isDirectMedia(url) {
            return try await directFile(url, client: client)
        }
        let page = try await client.html(url, userAgent: UserAgent.desktopSafari)
        let html = page.text
        let base = page.finalURL
        let graph = Extract.openGraphItems(html: html, base: base)
        var items = graph.items
        var seen = Set(items.compactMap { $0.best?.delivery.primaryURL.absoluteString })

        func add(_ kind: MediaKind, _ address: String, poster: URL? = nil) {
            guard let mediaURL = URL(string: HTMLText.decode(address), relativeTo: base)?.absoluteURL, seen.insert(mediaURL.absoluteString).inserted else { return }
            let ext = mediaURL.pathExtension.lowercased()
            guard ext != "m3u8", ext != "mpd" else { return }
            let variant = kind == .video ? Extract.video(mediaURL, codec: nil, container: ext.isEmpty ? "mp4" : ext, label: "page") : Extract.photo(mediaURL, label: "page")
            items.append(Extract.item(kind, [variant], thumbnail: poster))
        }
        for tag in HTMLText.allGroups(#"(<video[^>]*>)"#, in: html, options: [.caseInsensitive]) {
            let attributes = HTMLText.attributePairs(in: tag)
            if let src = attributes["src"] { add(.video, src, poster: attributes["poster"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }) }
        }
        for tag in HTMLText.allGroups(#"(<source[^>]*>)"#, in: html, options: [.caseInsensitive]) {
            let attributes = HTMLText.attributePairs(in: tag)
            if let src = attributes["src"], (attributes["type"] ?? "video").hasPrefix("video") { add(.video, src) }
        }
        for raw in HTMLText.allGroups(#"<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>"#, in: html, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            guard let json = try? JSONValue.parse(raw) else { continue }
            for object in json.allObjects(containing: "contentUrl") {
                if let address = object["contentUrl"].string {
                    let type = object["@type"].string ?? ""
                    add(type.contains("Video") ? .video : .photo, address, poster: object["thumbnailUrl"].url)
                }
            }
        }
        // Videos are what people come for; pictures that are only the page's share card follow.
        items.sort { ($0.kind == .video ? 0 : 1) < ($1.kind == .video ? 0 : 1) }
        guard !items.isEmpty else { throw StashyError.noMedia }
        let author = Author(name: graph.site ?? base.host ?? "", handle: nil, avatarURL: nil, profileURL: base)
        return Post(platform: .web, sourceURL: url, canonicalURL: base, author: author, title: graph.title, text: graph.description ?? "", createdAt: nil, items: items, extractor: "web-page.1")
    }

    private func directFile(_ url: URL, client: HTTPClient) async throws -> Post {
        let probe = await client.probe(url)
        let ext = url.pathExtension.lowercased()
        let type = probe?.contentType ?? ""
        let kind: MediaKind
        if type.hasPrefix("video") || ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext) { kind = .video }
        else if type.hasPrefix("audio") || ["m4a", "mp3", "aac", "wav", "ogg", "flac"].contains(ext) { kind = .audio }
        else if ext == "gif" || type == "image/gif" { kind = .gif }
        else if type.hasPrefix("image") || LinkParser.mediaExtensions.contains(ext) { kind = .photo }
        else { throw StashyError.noMedia }
        if let probe, !(probe.contentType.hasPrefix("video") || probe.contentType.hasPrefix("image") || probe.contentType.hasPrefix("audio") || probe.contentType.contains("octet-stream")) {
            throw StashyError.noMedia
        }
        var variant = MediaVariant(delivery: .file(probe?.finalURL ?? url), codec: nil, container: ext.isEmpty ? kind.defaultExtension : ext, sizeBytes: probe?.length, label: "file")
        if kind == .photo || kind == .gif { variant.codec = Extract.imageCodec(for: url) }
        let item = Extract.item(kind, [variant])
        return Post(platform: .web, sourceURL: url, canonicalURL: url, author: Author(name: url.host ?? ""), title: url.lastPathComponent, text: "", createdAt: nil, items: [item], extractor: "direct-file.1")
    }
}
