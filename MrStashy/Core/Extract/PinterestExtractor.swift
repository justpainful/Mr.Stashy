import Foundation

/// Pinterest's widget endpoint describes any public pin: the original image, every MP4
/// rendition of a video pin, and the pages of an idea pin. The pin page is read when the
/// widget has nothing.
struct PinterestExtractor: Extractor {
    let platform: Platform = .pinterest

    static func pinID(from url: URL) -> String? {
        let parts = LinkParser.pathComponents(url)
        guard let index = parts.firstIndex(of: "pin"), parts.count > index + 1 else { return nil }
        let id = parts[index + 1].prefix { $0.isNumber }
        return id.isEmpty ? nil : String(id)
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let id = Self.pinID(from: url) else { throw StashyError.unsupportedLink }
        let canonical = URL(string: "https://www.pinterest.com/pin/\(id)/")!
        var pin: JSONValue = .null
        var extractor = "pinterest-widget.1"
        var components = URLComponents(string: "https://widgets.pinterest.com/v3/pidgets/pins/info/")!
        components.queryItems = [.init(name: "pin_ids", value: id)]
        if let root = try? await client.json(components.url!, userAgent: UserAgent.desktopSafari), let first = root["data"].array.first, first.exists {
            pin = first
        } else {
            let page = try await client.html(canonical, userAgent: UserAgent.desktopSafari)
            extractor = "pinterest-page.1"
            for raw in HTMLText.allGroups(#"<script[^>]*type="application/json"[^>]*>(\{.*?\})</script>"#, in: page.text, options: [.dotMatchesLineSeparators]) {
                guard let json = try? JSONValue.parse(raw) else { continue }
                let candidates = json.allObjects(containing: "images").filter { $0["id"].string == id || $0["images"]["orig"].exists }
                if let found = candidates.first(where: { $0["id"].string == id }) ?? candidates.first {
                    pin = found
                    break
                }
            }
            if pin.isNull {
                let graph = Extract.openGraphItems(html: page.text, base: canonical)
                guard !graph.items.isEmpty else { throw StashyError.notFound }
                return Post(platform: .pinterest, sourceURL: url, canonicalURL: canonical, author: Author(name: graph.site ?? "Pinterest"), title: graph.title, text: graph.description ?? "", createdAt: nil, items: graph.items, notes: [L10n.value("note.previewOnly")], extractor: "pinterest-opengraph.1")
            }
        }

        var items: [MediaItem] = []
        if let video = Self.videoItem(from: pin["videos"]["video_list"], thumbnail: pin["images"]["orig"]["url"].url) {
            items.append(video)
        }
        // Idea pins: ordered pages, each a picture or a clip.
        for page in pin["story_pin_data"]["pages"].array {
            for block in page["blocks"].array {
                if let video = Self.videoItem(from: block["video"]["video_list"], thumbnail: block["image"]["images"]["originals"]["url"].url) {
                    items.append(video)
                } else if let imageURL = block["image"]["images"]["originals"]["url"].url {
                    let original = block["image"]["images"]["originals"]
                    items.append(Extract.item(.photo, [Extract.photo(imageURL, width: original["width"].int, height: original["height"].int, label: "originals")]))
                }
            }
            if let video = Self.videoItem(from: page["video"]["video_list"], thumbnail: nil) { items.append(video) }
        }
        if items.isEmpty {
            let original = pin["images"]["orig"]
            if let imageURL = original["url"].url {
                items.append(Extract.item(.photo, [Extract.photo(imageURL, width: original["width"].int, height: original["height"].int, label: "orig")], alt: pin["alt_text"].string))
            } else if let largest = pin["images"].object.values.compactMap({ $0["url"].url.map { ($0, $0.absoluteString.count) } }).max(by: { $0.1 < $1.1 })?.0 {
                items.append(Extract.item(.photo, [Extract.photo(largest, label: "largest")]))
            }
        }
        guard !items.isEmpty else { throw StashyError.noMedia }

        let pinner = pin["pinner"].exists ? pin["pinner"] : pin["native_creator"]
        let author = Author(
            name: pinner["full_name"].string ?? pinner["username"].string ?? "",
            handle: pinner["username"].string,
            avatarURL: pinner["image_large_url"].url ?? pinner["image_medium_url"].url,
            profileURL: pinner["username"].string.flatMap { URL(string: "https://www.pinterest.com/\($0)/") }
        )
        let title = pin["title"].string ?? pin["grid_title"].string
        let description = pin["description"].string ?? pin["closeup_unified_description"].string ?? ""
        return Post(platform: .pinterest, sourceURL: url, canonicalURL: canonical, author: author, title: title?.isEmpty == true ? nil : title, text: description, createdAt: Extract.date(fromISO: pin["created_at"].string) ?? Self.pinDate(pin["created_at"].string), items: items, extractor: extractor)
    }

    private static func videoItem(from list: JSONValue, thumbnail: URL?) -> MediaItem? {
        var variants: [MediaVariant] = []
        var duration: TimeInterval?
        for (key, rendition) in list.object {
            guard let renditionURL = rendition["url"].url else { continue }
            if renditionURL.pathExtension.lowercased() == "m3u8" {
                variants.append(MediaVariant(delivery: .hls(renditionURL), width: rendition["width"].int, height: rendition["height"].int, codec: "H.264", container: "mp4", label: key))
            } else {
                variants.append(Extract.video(renditionURL, width: rendition["width"].int, height: rendition["height"].int, label: key))
            }
            if duration == nil, let ms = rendition["duration"].double { duration = ms / 1000 }
        }
        guard !variants.isEmpty else { return nil }
        // Files before streams at equal size.
        variants.sort { lhs, rhs in
            if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
            if case .file = lhs.delivery, case .hls = rhs.delivery { return true }
            return false
        }
        return Extract.item(.video, variants, thumbnail: thumbnail, duration: duration)
    }

    /// Pinterest writes dates like "Tue, 20 Jun 2023 14:03:26 +0000".
    private static func pinDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }
}
