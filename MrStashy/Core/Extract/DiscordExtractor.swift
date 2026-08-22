import Foundation

/// Discord messages are never public; reading one needs a bot that is a member of the
/// server. Stashy accepts only a bot token the person created themselves, never a user
/// account token, and uses it for nothing but fetching the linked message.
struct DiscordExtractor: Extractor {
    let platform: Platform = .discord

    static func reference(from url: URL) -> (channel: String, message: String)? {
        let parts = LinkParser.pathComponents(url)
        guard let index = parts.firstIndex(of: "channels"), parts.count > index + 3 else { return nil }
        return (parts[index + 2], parts[index + 3])
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let reference = Self.reference(from: url) else { throw StashyError.unsupportedLink }
        guard let token = credentials.value(for: .discordBotToken), !token.isEmpty else { throw StashyError.loginRequired }
        let bot = token.hasPrefix("Bot ") ? token : "Bot \(token)"
        let endpoint = URL(string: "https://discord.com/api/v10/channels/\(reference.channel)/messages/\(reference.message)")!
        let response = try await client.get(endpoint, userAgent: "DiscordBot (https://github.com/justpainful/Mr.Stashy, 1.0)", headers: ["Authorization": bot], accept: "application/json")
        switch response.status {
        case 200: break
        case 401: throw StashyError.loginRequired
        case 403: throw StashyError.privateContent
        case 404: throw StashyError.notFound
        case 429: throw StashyError.rateLimited
        default: throw StashyError.network
        }
        let message = try response.json()
        var items: [MediaItem] = []
        for attachment in message["attachments"].array {
            guard let fileURL = attachment["url"].url else { continue }
            let type = attachment["content_type"].string ?? ""
            let ext = (attachment["filename"].string as NSString?)?.pathExtension.lowercased() ?? fileURL.pathExtension.lowercased()
            let kind: MediaKind = type.hasPrefix("video") || ["mp4", "mov", "webm"].contains(ext) ? .video : type.hasPrefix("audio") || ["mp3", "m4a", "ogg", "wav"].contains(ext) ? .audio : ext == "gif" ? .gif : type.hasPrefix("image") || LinkParser.mediaExtensions.contains(ext) ? .photo : .photo
            guard kind != .photo || type.hasPrefix("image") || LinkParser.mediaExtensions.contains(ext) else { continue }
            var variant = kind == .video ? Extract.video(fileURL, width: attachment["width"].int, height: attachment["height"].int, codec: nil, container: ext.isEmpty ? "mp4" : ext, label: "attachment", size: attachment["size"].int64) : Extract.photo(fileURL, width: attachment["width"].int, height: attachment["height"].int, label: "attachment", size: attachment["size"].int64)
            if kind == .audio { variant.container = ext.isEmpty ? "m4a" : ext; variant.codec = nil }
            items.append(Extract.item(kind, [variant], alt: attachment["description"].string ?? attachment["filename"].string))
        }
        for embed in message["embeds"].array {
            if let video = embed["video"]["url"].url, video.pathExtension.lowercased() == "mp4" {
                items.append(Extract.item(.video, [Extract.video(video, width: embed["video"]["width"].int, height: embed["video"]["height"].int, label: "embed")], thumbnail: embed["thumbnail"]["url"].url))
            } else if let image = embed["image"]["url"].url {
                items.append(Extract.item(.photo, [Extract.photo(image, width: embed["image"]["width"].int, height: embed["image"]["height"].int, label: "embed")]))
            }
        }
        guard !items.isEmpty else { throw StashyError.noMedia }
        let user = message["author"]
        let avatar = user["avatar"].string.flatMap { URL(string: "https://cdn.discordapp.com/avatars/\(user["id"].string ?? "")/\($0).png?size=256") }
        let author = Author(name: user["global_name"].string ?? user["username"].string ?? "", handle: user["username"].string, avatarURL: avatar, profileURL: nil)
        return Post(platform: .discord, sourceURL: url, canonicalURL: url, author: author, title: nil, text: message["content"].string ?? "", createdAt: Extract.date(fromISO: message["timestamp"].string), items: items, extractor: "discord-bot-api.1")
    }
}
