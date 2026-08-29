import Foundation

/// Reddit publishes every public post as JSON by appending `.json`. Videos arrive as DASH —
/// a video-only MP4 and a separate audio MP4 — which the assembler muxes into one file.
struct RedditExtractor: Extractor {
    let platform: Platform = .reddit

    static func postID(from url: URL) -> String? {
        let parts = LinkParser.pathComponents(url)
        if let index = parts.firstIndex(of: "comments"), parts.count > index + 1 { return parts[index + 1] }
        if let index = parts.firstIndex(of: "gallery"), parts.count > index + 1 { return parts[index + 1] }
        if url.host?.lowercased() == "redd.it", let first = parts.first { return first }
        return nil
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let id = Self.postID(from: url) else { throw StashyError.unsupportedLink }
        let root = try await listing(id: id, client: client)
        var data = root[0]["data"]["children"][0]["data"]
        guard data.exists else { throw StashyError.notFound }
        if data["removed_by_category"].exists, data["removed_by_category"].string != nil { throw StashyError.notFound }
        if let crosspost = data["crosspost_parent_list"].array.first, crosspost.exists { data = crosspost }

        let permalink = data["permalink"].string.flatMap { URL(string: "https://www.reddit.com\($0)") } ?? url
        let author = Author(
            name: data["author"].string.map { "u/\($0)" } ?? "",
            handle: data["author"].string,
            avatarURL: nil,
            profileURL: data["author"].string.flatMap { URL(string: "https://www.reddit.com/user/\($0)") }
        )
        var items = try await mediaItems(for: data, client: client)
        var notes: [String] = []

        // A link post pointing at another supported source: read it with that source's extractor.
        if items.isEmpty, let linked = data["url_overridden_by_dest"].url ?? data["url"].url {
            let linkedPlatform = LinkParser.platform(for: linked)
            if LinkParser.isDirectMedia(linked) {
                let ext = linked.pathExtension.lowercased()
                let kind: MediaKind = ext == "gif" ? .gif : (["mp4", "mov", "webm"].contains(ext) ? .video : .photo)
                let variant = kind == .video ? Extract.video(linked, codec: nil, container: ext, label: "link") : Extract.photo(linked, label: "link")
                items = [Extract.item(kind, [variant])]
            } else if linkedPlatform != .reddit && linkedPlatform != .web, let extractor = ExtractorRegistry.all[linkedPlatform] {
                let linkedPost = try await extractor.extract(linked, client: client, credentials: credentials)
                items = linkedPost.items
                notes.append(L10n.format("note.redditLinked", L10n.value(linkedPlatform.titleKey)))
            }
        }
        guard !items.isEmpty else { throw StashyError.noMedia }

        var text = data["selftext"].string ?? ""
        if text.isEmpty, let title = data["title"].string, items.isEmpty { text = title }
        return Post(
            platform: .reddit, sourceURL: url, canonicalURL: permalink, author: author,
            title: data["title"].string, text: text, createdAt: Extract.date(fromUnix: data["created_utc"].double),
            items: items, notes: notes, extractor: "reddit-json.1"
        )
    }

    private func listing(id: String, client: HTTPClient) async throws -> JSONValue {
        let candidates = [
            (URL(string: "https://www.reddit.com/comments/\(id).json?raw_json=1")!, UserAgent.stashy),
            (URL(string: "https://api.reddit.com/comments/\(id)?raw_json=1")!, UserAgent.stashy),
            (URL(string: "https://old.reddit.com/comments/\(id).json?raw_json=1")!, UserAgent.desktopSafari)
        ]
        var last: StashyError = .network
        for (endpoint, agent) in candidates {
            do {
                let response = try await client.get(endpoint, userAgent: agent, accept: "application/json")
                if response.status == 200, response.contentType.contains("json") { return try response.json() }
                if response.status == 404 { throw StashyError.notFound }
                if response.status == 429 { throw StashyError.rateLimited }
                last = response.status == 403 ? .blocked : .network
            } catch let error as StashyError {
                if error == .notFound || error == .rateLimited { throw error }
                last = error
            } catch {
                last = .network
            }
        }
        throw last
    }

    private func mediaItems(for data: JSONValue, client: HTTPClient) async throws -> [MediaItem] {
        var items: [MediaItem] = []

        // Galleries keep the poster's order in gallery_data; media_metadata holds the files.
        let galleryItems = data["gallery_data"]["items"].array
        if !galleryItems.isEmpty {
            let metadata = data["media_metadata"]
            for entry in galleryItems {
                guard let mediaID = entry["media_id"].string else { continue }
                let meta = metadata[mediaID]
                if let item = Self.galleryItem(id: mediaID, meta: meta, caption: entry["caption"].string) { items.append(item) }
            }
            return items
        }

        if data["is_video"].bool == true || data["media"]["reddit_video"].exists || data["secure_media"]["reddit_video"].exists {
            let video = data["media"]["reddit_video"].exists ? data["media"]["reddit_video"] : data["secure_media"]["reddit_video"]
            if let item = await Self.redditVideo(video, thumbnail: Self.preview(data), client: client) { items.append(item) }
            return items
        }

        if let link = data["url_overridden_by_dest"].url ?? data["url"].url {
            let host = link.host?.lowercased() ?? ""
            let ext = link.pathExtension.lowercased()
            if host == "i.redd.it" || host == "preview.redd.it" {
                let source = data["preview"]["images"][0]["source"]
                if ext == "gif" {
                    var variants: [MediaVariant] = []
                    if let mp4 = data["preview"]["images"][0]["variants"]["mp4"]["source"]["url"].url {
                        variants.append(Extract.video(mp4, width: source["width"].int, height: source["height"].int, label: "mp4 rendition"))
                    }
                    variants.append(Extract.photo(link, width: source["width"].int, height: source["height"].int, label: "original gif"))
                    items.append(Extract.item(.gif, variants))
                } else {
                    items.append(Extract.item(.photo, [Extract.photo(link, width: source["width"].int, height: source["height"].int, label: "original")]))
                }
            } else if host == "v.redd.it" {
                if let item = await Self.redditVideo(data["media"]["reddit_video"], fallbackBase: link, thumbnail: Self.preview(data), client: client) { items.append(item) }
            }
        }

        // A text post can still embed pictures inline.
        if items.isEmpty {
            for (mediaID, meta) in data["media_metadata"].object {
                if let item = Self.galleryItem(id: mediaID, meta: meta, caption: nil) { items.append(item) }
            }
            items.sort { ($0.best?.delivery.primaryURL.absoluteString ?? "") < ($1.best?.delivery.primaryURL.absoluteString ?? "") }
        }
        return items
    }

    private static func preview(_ data: JSONValue) -> URL? {
        data["preview"]["images"][0]["source"]["url"].url ?? data["thumbnail"].url
    }

    private static func galleryItem(id: String, meta: JSONValue, caption: String?) -> MediaItem? {
        guard meta["status"].string != "failed" else { return nil }
        let source = meta["s"]
        let mime = meta["m"].string ?? "image/jpeg"
        let ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
        let width = source["x"].int
        let height = source["y"].int
        if let mp4 = source["mp4"].url {
            var variants = [Extract.video(mp4, width: width, height: height, label: "mp4 rendition")]
            if let gif = source["gif"].url { variants.append(Extract.photo(gif, width: width, height: height, label: "original gif")) }
            return Extract.item(.gif, variants, alt: caption)
        }
        var variants: [MediaVariant] = []
        if let original = URL(string: "https://i.redd.it/\(id).\(ext == "jpeg" ? "jpg" : ext)") {
            variants.append(Extract.photo(original, width: width, height: height, label: "original"))
        }
        if let preview = source["u"].url { variants.append(Extract.photo(preview, width: width, height: height, label: "preview")) }
        guard !variants.isEmpty else { return nil }
        return Extract.item(.photo, variants, alt: caption)
    }

    /// DASH video: read the manifest for every rendition, pair each with the audio track.
    private static func redditVideo(_ video: JSONValue, fallbackBase: URL? = nil, thumbnail: URL?, client: HTTPClient) async -> MediaItem? {
        let fallback = video["fallback_url"].url ?? fallbackBase
        guard let fallback else { return nil }
        let base: URL = {
            if let range = fallback.absoluteString.range(of: "/DASH_") { return URL(string: String(fallback.absoluteString[..<range.lowerBound]))! }
            return fallback
        }()
        let width = video["width"].int
        let height = video["height"].int
        let duration = video["duration"].double
        let hasAudio = video["has_audio"].bool ?? true
        var renditions: [(name: String, width: Int?, height: Int?, bandwidth: Int?)] = []
        var audioName: String?

        if let dash = video["dash_url"].url ?? URL(string: base.absoluteString + "/DASHPlaylist.mpd"), let manifest = try? await client.get(dash, userAgent: UserAgent.desktopSafari), manifest.status == 200 {
            let xml = manifest.text
            for block in HTMLText.allGroups(#"(<Representation[^>]*>.*?</Representation>)"#, in: xml, options: [.dotMatchesLineSeparators]) {
                guard let name = HTMLText.firstGroup(#"<BaseURL>([^<]+)</BaseURL>"#, in: block) else { continue }
                let attributes = HTMLText.attributePairs(in: block.components(separatedBy: ">").first ?? "")
                if name.uppercased().contains("AUDIO") {
                    if audioName == nil || (Int(attributes["bandwidth"] ?? "") ?? 0) > 0 { audioName = name }
                } else {
                    renditions.append((name, Int(attributes["width"] ?? ""), Int(attributes["height"] ?? ""), Int(attributes["bandwidth"] ?? "")))
                }
            }
        }
        if renditions.isEmpty {
            let fallbackName = fallback.lastPathComponent
            renditions.append((fallbackName.isEmpty ? "DASH_720.mp4" : fallbackName, width, height, video["bitrate_kbps"].int.map { $0 * 1000 }))
        }
        if hasAudio, audioName == nil { audioName = "DASH_AUDIO_128.mp4" }

        var variants: [MediaVariant] = []
        for rendition in renditions {
            guard let videoURL = URL(string: base.absoluteString + "/" + rendition.name) else { continue }
            let delivery: MediaDelivery
            if let audioName, hasAudio, let audioURL = URL(string: base.absoluteString + "/" + audioName) {
                delivery = .muxed(video: videoURL, audio: audioURL)
            } else {
                delivery = .file(videoURL)
            }
            let label = HTMLText.firstGroup(#"DASH_(\d+)"#, in: rendition.name).map { "\($0)p" } ?? rendition.name
            variants.append(MediaVariant(delivery: delivery, width: rendition.width, height: rendition.height ?? Int(HTMLText.firstGroup(#"DASH_(\d+)"#, in: rendition.name) ?? ""), bitrate: rendition.bandwidth, codec: "H.264", container: "mp4", label: label))
        }
        guard !variants.isEmpty else { return nil }
        return Extract.item(.video, variants, thumbnail: thumbnail, duration: duration)
    }
}
