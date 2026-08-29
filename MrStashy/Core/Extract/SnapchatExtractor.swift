import Foundation

/// Snapchat's web pages (Spotlight, public profiles and stories) inline their data as a
/// Next.js payload; the Spotlight file it names is a plain MP4.
struct SnapchatExtractor: Extractor {
    let platform: Platform = .snapchat

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        let page = try await client.html(url, userAgent: UserAgent.desktopChrome)
        let html = page.text
        guard let raw = HTMLText.script(withID: "__NEXT_DATA__", in: html), let root = try? JSONValue.parse(raw) else {
            return try Self.fromOpenGraph(html: html, url: url)
        }
        let props = root["props"]["pageProps"]
        var items: [MediaItem] = []
        var author = Author(name: "Snapchat")
        var text = ""
        var createdAt: Date?

        let metadata = props["videoMetadata"]
        if let content = metadata["contentUrl"].url {
            items.append(Extract.item(.video, [Extract.video(content, width: metadata["width"].int, height: metadata["height"].int, label: "spotlight")], thumbnail: metadata["thumbnailUrl"].url, duration: metadata["durationMs"].double.map { $0 / 1000 }, alt: metadata["name"].string))
            text = metadata["name"].string ?? metadata["embeddedTextCaption"].string ?? ""
            createdAt = Extract.date(fromUnix: metadata["uploadDateMs"].double)
            let creator = metadata["creator"]["personCreator"].exists ? metadata["creator"]["personCreator"] : metadata["creator"]["publisherCreator"]
            author = Author(name: creator["name"].string ?? creator["username"].string ?? "Snapchat", handle: creator["username"].string, avatarURL: nil, profileURL: creator["url"].url)
        }

        // Public stories and profile highlights list their snaps with media addresses.
        if items.isEmpty {
            for snap in props.allObjects(containing: "snapUrls") {
                let urls = snap["snapUrls"]
                guard let media = urls["mediaUrl"].url else { continue }
                let isVideo = (snap["snapMediaType"].int ?? 1) == 1 || media.pathExtension.lowercased() == "mp4"
                items.append(Extract.item(isVideo ? .video : .photo, [isVideo ? Extract.video(media, label: "story") : Extract.photo(media, label: "story")], thumbnail: urls["mediaPreviewUrl"]["value"].url ?? urls["mediaPreviewUrl"].url, duration: nil, alt: snap["snapTitle"].string))
            }
            let profile = props["userProfile"]["publicProfileInfo"].exists ? props["userProfile"]["publicProfileInfo"] : props["userProfile"]["publisherProfileInfo"]
            if profile.exists {
                author = Author(name: profile["title"].string ?? profile["username"].string ?? "Snapchat", handle: profile["username"].string, avatarURL: profile["profilePictureUrl"].url, profileURL: profile["username"].string.flatMap { URL(string: "https://www.snapchat.com/add/\($0)") })
            }
        }

        if items.isEmpty {
            return try Self.fromOpenGraph(html: html, url: url)
        }
        return Post(platform: .snapchat, sourceURL: url, canonicalURL: page.finalURL, author: author, title: nil, text: text, createdAt: createdAt, items: items, extractor: "snapchat-nextdata.1")
    }

    private static func fromOpenGraph(html: String, url: URL) throws -> Post {
        let graph = Extract.openGraphItems(html: html, base: url)
        guard !graph.items.isEmpty else { throw StashyError.noMedia }
        return Post(platform: .snapchat, sourceURL: url, canonicalURL: url, author: Author(name: graph.site ?? "Snapchat"), title: graph.title, text: graph.description ?? "", createdAt: nil, items: graph.items, notes: [L10n.value("note.previewOnly")], extractor: "snapchat-opengraph.1")
    }
}
