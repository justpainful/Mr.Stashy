import Foundation

/// Three public ways to read a TikTok post, tried in order of quality:
/// 1. the post page itself, whose embedded state lists every bitrate (up to 1080p, no watermark);
/// 2. the embed player's item endpoint, which serves the H.264 play file directly;
/// 3. the embed page, the last thing TikTok serves to everyone.
struct TikTokExtractor: Extractor {
    let platform: Platform = .tikTok

    private static let downloadHeaders = ["Referer": "https://www.tiktok.com/", "User-Agent": UserAgent.desktopSafari]

    static func itemID(from url: URL) -> String? {
        let parts = LinkParser.pathComponents(url)
        if let index = parts.firstIndex(where: { $0 == "video" || $0 == "photo" }), parts.count > index + 1 {
            let id = parts[index + 1].prefix { $0.isNumber }
            return id.count >= 15 ? String(id) : nil
        }
        if let last = parts.last, last.count >= 15, last.allSatisfy(\.isNumber) { return last }
        return nil
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let id = Self.itemID(from: url) else { throw StashyError.unsupportedLink }
        var failures: [StashyError] = []

        if let post = try await attempt({ try await fromPage(id: id, url: url, client: client) }, failures: &failures) { return post }
        if let post = try await attempt({ try await fromPlayerAPI(id: id, url: url, client: client) }, failures: &failures) { return post }
        if let post = try await attempt({ try await fromEmbed(id: id, url: url, client: client) }, failures: &failures) { return post }

        // The most specific failure wins: "private" beats "changed".
        let priority: [StashyError] = [.privateContent, .notFound, .loginRequired, .rateLimited, .noMedia, .network, .sourceChanged]
        throw priority.first { failures.contains($0) } ?? .sourceChanged
    }

    private func attempt(_ work: () async throws -> Post, failures: inout [StashyError]) async throws -> Post? {
        do {
            return try await work()
        } catch let error as StashyError {
            failures.append(error)
            return nil
        } catch {
            failures.append(StashyError.from(error))
            return nil
        }
    }

    // MARK: Tier 1 — the post page

    private func fromPage(id: String, url: URL, client: HTTPClient) async throws -> Post {
        let pageURL = URL(string: "https://www.tiktok.com/@_/video/\(id)")!
        let page = try await client.html(pageURL, userAgent: UserAgent.desktopSafari)
        guard let raw = HTMLText.script(withID: "__UNIVERSAL_DATA_FOR_REHYDRATION__", in: page.text) else { throw StashyError.sourceChanged }
        let root = try JSONValue.parse(raw)
        let detail = root["__DEFAULT_SCOPE__"]["webapp.video-detail"]
        if let code = detail["statusCode"].int, code != 0 {
            switch code {
            case 10_204, 10_216: throw StashyError.notFound
            case 10_222, 10_231: throw StashyError.privateContent
            default: throw StashyError.sourceChanged
            }
        }
        let item = detail["itemInfo"]["itemStruct"]
        guard item.exists else { throw StashyError.sourceChanged }

        var items: [MediaItem] = []
        let video = item["video"]
        let duration = video["duration"].double
        let cover = video["originCover"].url ?? video["cover"].url

        if item["imagePost"]["images"].exists {
            for image in item["imagePost"]["images"].array {
                guard let imageURL = image["imageURL"]["urlList"].array.first?.url else { continue }
                items.append(Extract.item(.photo, [Extract.photo(imageURL, width: image["imageWidth"].int, height: image["imageHeight"].int, label: "original", headers: Self.downloadHeaders)]))
            }
        } else {
            var variants: [MediaVariant] = []
            for bitrate in video["bitrateInfo"].array {
                let address = bitrate["PlayAddr"]
                guard let playURL = address["UrlList"].array.first?.url else { continue }
                let codec = bitrate["CodecType"].string ?? ""
                variants.append(Extract.video(
                    playURL, width: address["Width"].int, height: address["Height"].int,
                    bitrate: bitrate["Bitrate"].int, codec: codec.contains("265") || codec.contains("bytevc1") ? "H.265" : "H.264",
                    label: bitrate["GearName"].string ?? "play", headers: Self.downloadHeaders, size: address["DataSize"].int64
                ))
            }
            if variants.isEmpty, let playURL = video["playAddr"].url {
                variants.append(Extract.video(playURL, width: video["width"].int, height: video["height"].int, bitrate: video["bitrate"].int, label: "play", headers: Self.downloadHeaders))
            }
            guard !variants.isEmpty else { throw StashyError.noMedia }
            items.append(Extract.item(.video, variants, thumbnail: cover, duration: duration, alt: item["desc"].string))
        }

        let authorNode = item["author"]
        let author = Author(
            name: authorNode["nickname"].string ?? authorNode["uniqueId"].string ?? "",
            handle: authorNode["uniqueId"].string,
            avatarURL: authorNode["avatarLarger"].url ?? authorNode["avatarMedium"].url,
            profileURL: authorNode["uniqueId"].string.flatMap { URL(string: "https://www.tiktok.com/@\($0)") },
            isVerified: authorNode["verified"].bool ?? false
        )
        return Post(
            platform: .tikTok, sourceURL: url, canonicalURL: Self.canonical(handle: author.handle, id: id, isPhoto: items.first?.kind == .photo),
            author: author, title: nil, text: item["desc"].string ?? "",
            createdAt: Extract.date(fromUnix: item["createTime"].double),
            items: items, extractor: "tiktok-page.1"
        )
    }

    // MARK: Tier 2 — the embed player's item endpoint

    private func fromPlayerAPI(id: String, url: URL, client: HTTPClient) async throws -> Post {
        let endpoint = URL(string: "https://www.tiktok.com/player/api/v1/items?item_ids=\(id)")!
        let root = try await client.json(endpoint, userAgent: UserAgent.desktopSafari, headers: ["Referer": "https://www.tiktok.com/"])
        guard let item = root["items"].array.first else {
            let code = root["results"].array.first?["code"].string ?? ""
            throw code == "nil_core_data" || code.contains("not_exist") ? StashyError.notFound : StashyError.sourceChanged
        }
        let info = item["video_info"]
        var items: [MediaItem] = []
        let cover = info["origin_cover"]["url_list"].array.first?.url ?? info["cover"]["url_list"].array.first?.url
        let duration = (info["meta"]["duration"].double).map { $0 / 1000 }

        for image in item["image_post_info"]["images"].array {
            let display = image["display_image"]
            guard let imageURL = display["url_list"].array.first?.url else { continue }
            items.append(Extract.item(.photo, [Extract.photo(imageURL, width: display["width"].int, height: display["height"].int, label: "original", headers: Self.downloadHeaders)]))
        }
        if items.isEmpty {
            var variants: [MediaVariant] = []
            for profile in info["profiles"].array {
                let address = profile["play_addr"]
                guard let playURL = address["url_list"].array.first?.url else { continue }
                let codec = profile["codec_type"].string ?? "h264"
                variants.append(Extract.video(
                    playURL, width: address["width"].int ?? info["meta"]["width"].int, height: address["height"].int ?? info["meta"]["height"].int,
                    bitrate: profile["bitrate"].int, fps: profile["fps"].double,
                    codec: codec.contains("265") || codec.contains("bytevc1") ? "H.265" : "H.264",
                    label: profile["gear_name"].string ?? "play", headers: Self.downloadHeaders, size: address["data_size"].int64
                ))
            }
            if variants.isEmpty, let playURL = info["url_list"].array.first?.url {
                variants.append(Extract.video(playURL, width: info["meta"]["width"].int, height: info["meta"]["height"].int, bitrate: info["meta"]["bitrate"].int, label: "play", headers: Self.downloadHeaders))
            }
            guard !variants.isEmpty else { throw StashyError.noMedia }
            items.append(Extract.item(.video, variants, thumbnail: cover, duration: duration, alt: item["desc"].string))
        }

        let authorNode = item["author_info"]
        let author = Author(
            name: authorNode["nickname"].string ?? authorNode["unique_id"].string ?? "",
            handle: authorNode["unique_id"].string,
            avatarURL: authorNode["avatar_url_list"].array.first?.url,
            profileURL: authorNode["unique_id"].string.flatMap { URL(string: "https://www.tiktok.com/@\($0)") }
        )
        return Post(
            platform: .tikTok, sourceURL: url, canonicalURL: Self.canonical(handle: author.handle, id: id, isPhoto: items.first?.kind == .photo),
            author: author, title: nil, text: item["desc"].string ?? "", createdAt: Extract.date(fromUnix: item["create_time"].double),
            items: items, extractor: "tiktok-player.1"
        )
    }

    // MARK: Tier 3 — the embed page

    private func fromEmbed(id: String, url: URL, client: HTTPClient) async throws -> Post {
        let embedURL = URL(string: "https://www.tiktok.com/embed/v2/\(id)")!
        let page = try await client.html(embedURL, userAgent: UserAgent.desktopSafari)
        guard let raw = HTMLText.script(withID: "__FRONTITY_CONNECT_STATE__", in: page.text) else { throw StashyError.sourceChanged }
        let root = try JSONValue.parse(raw)
        let data = root["source"]["data"]["/embed/v2/\(id)"]["videoData"]
        let infos = data["itemInfos"]
        guard infos.exists else { throw StashyError.notFound }

        var items: [MediaItem] = []
        for image in data["imagePostInfo"]["images"].array {
            guard let imageURL = image["imageURL"]["urlList"].array.first?.url ?? image["url"].url else { continue }
            items.append(Extract.item(.photo, [Extract.photo(imageURL, width: image["imageWidth"].int, height: image["imageHeight"].int, label: "original", headers: Self.downloadHeaders)]))
        }
        if items.isEmpty {
            let meta = infos["video"]["videoMeta"]
            let variants = infos["video"]["urls"].array.compactMap(\.url).prefix(1).map { playURL in
                Extract.video(playURL, width: meta["width"].int, height: meta["height"].int, label: "play", headers: Self.downloadHeaders)
            }
            guard !variants.isEmpty else { throw StashyError.noMedia }
            items.append(Extract.item(.video, Array(variants), thumbnail: infos["coversOrigin"].array.first?.url ?? infos["covers"].array.first?.url, duration: meta["duration"].double, alt: infos["text"].string))
        }
        let authorNode = data["authorInfos"]
        let author = Author(
            name: authorNode["nickName"].string ?? authorNode["uniqueId"].string ?? "",
            handle: authorNode["uniqueId"].string,
            avatarURL: authorNode["covers"].array.first?.url,
            profileURL: authorNode["uniqueId"].string.flatMap { URL(string: "https://www.tiktok.com/@\($0)") },
            isVerified: authorNode["verified"].bool ?? false
        )
        return Post(
            platform: .tikTok, sourceURL: url, canonicalURL: Self.canonical(handle: author.handle, id: id, isPhoto: items.first?.kind == .photo),
            author: author, title: nil, text: infos["text"].string ?? "", createdAt: Extract.date(fromUnix: infos["createTime"].double),
            items: items, extractor: "tiktok-embed.1"
        )
    }

    private static func canonical(handle: String?, id: String, isPhoto: Bool) -> URL {
        URL(string: "https://www.tiktok.com/@\(handle ?? "_")/\(isPhoto ? "photo" : "video")/\(id)")!
    }
}
