import Foundation

/// Imgur's own web client reads posts and albums through one endpoint that lists each file
/// at its original address. Stashy uses the same public client identifier, or the person's
/// own when they add one.
struct ImgurExtractor: Extractor {
    let platform: Platform = .imgur

    private static let webClientID = "546c25a59c58ad7"

    static func reference(from url: URL) -> (id: String, isAlbum: Bool)? {
        let parts = LinkParser.pathComponents(url)
        guard let first = parts.first else { return nil }
        func hash(_ slug: String) -> String {
            // Gallery slugs end in the hash: "my-title-AbCdEf".
            let last = slug.split(separator: "-").last.map(String.init) ?? slug
            return String(last.prefix { $0.isLetter || $0.isNumber })
        }
        switch first {
        case "a", "album": return parts.count > 1 ? (hash(parts[1]), true) : nil
        case "gallery", "t", "r":
            guard let slug = parts.last, slug != first else { return nil }
            return (hash(slug), true)
        default:
            let id = first.split(separator: ".").first.map(String.init) ?? first
            return (hash(id), false)
        }
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let reference = Self.reference(from: url), !reference.id.isEmpty else { throw StashyError.unsupportedLink }
        let clientID = credentials.value(for: .imgurClientID).flatMap { $0.isEmpty ? nil : $0 } ?? Self.webClientID
        var root: JSONValue = .null
        var lastStatus = 0
        // Gallery links may point at a single image or an album; try both shapes.
        let kinds = reference.isAlbum ? ["albums", "media"] : ["media", "albums"]
        for kind in kinds {
            var components = URLComponents(string: "https://api.imgur.com/post/v1/\(kind)/\(reference.id)")!
            components.queryItems = [.init(name: "client_id", value: clientID), .init(name: "include", value: "media,account")]
            let response = try await client.get(components.url!, userAgent: UserAgent.desktopSafari, accept: "application/json")
            lastStatus = response.status
            if response.status == 200, let json = try? response.json(), !json["media"].array.isEmpty {
                root = json
                break
            }
        }
        guard root.exists else {
            switch lastStatus {
            case 404: throw StashyError.notFound
            case 429: throw StashyError.rateLimited
            case 401, 403: throw StashyError.blocked
            default: throw StashyError.sourceChanged
            }
        }
        var items: [MediaItem] = []
        for media in root["media"].array {
            guard let fileURL = media["url"].url else { continue }
            let width = media["width"].int
            let height = media["height"].int
            let size = media["size"].int64
            let alt = [media["name"].string, media["metadata"]["title"].string, media["metadata"]["description"].string].compactMap { $0 }.first { !$0.isEmpty }
            if media["type"].string == "video" || fileURL.pathExtension.lowercased() == "mp4" {
                let isGIF = media["metadata"]["is_animated"].bool == true && (media["metadata"]["has_sound"].bool == false)
                items.append(Extract.item(isGIF ? .gif : .video, [Extract.video(fileURL, width: width, height: height, label: "original", size: size)], thumbnail: URL(string: "https://i.imgur.com/\(media["id"].string ?? "").jpg"), duration: media["metadata"]["duration"].double, alt: alt))
            } else {
                items.append(Extract.item(.photo, [Extract.photo(fileURL, width: width, height: height, label: "original", size: size)], alt: alt))
            }
        }
        guard !items.isEmpty else { throw StashyError.noMedia }
        let account = root["account"]
        let author = Author(
            name: account["username"].string ?? "Imgur",
            handle: account["username"].string,
            avatarURL: account["avatar_url"].url,
            profileURL: account["username"].string.flatMap { URL(string: "https://imgur.com/user/\($0)") }
        )
        let canonical = URL(string: root["is_album"].bool == true ? "https://imgur.com/a/\(reference.id)" : "https://imgur.com/\(reference.id)") ?? url
        return Post(platform: .imgur, sourceURL: url, canonicalURL: canonical, author: author, title: root["title"].string.flatMap { $0.isEmpty ? nil : $0 }, text: root["description"].string ?? "", createdAt: Extract.date(fromISO: root["created_at"].string), items: items, extractor: "imgur-post-api.1")
    }
}
