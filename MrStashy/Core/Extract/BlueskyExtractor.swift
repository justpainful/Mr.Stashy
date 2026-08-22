import Foundation

/// Bluesky is an open network: the post record names the exact blob a person uploaded, and
/// their hosting server serves that blob unchanged. So Stashy keeps the original upload —
/// the real highest quality — and only falls back to the CDN renditions.
struct BlueskyExtractor: Extractor {
    let platform: Platform = .bluesky

    static func reference(from url: URL) -> (actor: String, rkey: String)? {
        let parts = LinkParser.pathComponents(url)
        guard let profile = parts.firstIndex(of: "profile"), parts.count > profile + 3, parts[profile + 2] == "post" else { return nil }
        return (parts[profile + 1], parts[profile + 3])
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let reference = Self.reference(from: url) else { throw StashyError.unsupportedLink }
        let did: String
        if reference.actor.hasPrefix("did:") {
            did = reference.actor
        } else {
            var components = URLComponents(string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle")!
            components.queryItems = [.init(name: "handle", value: reference.actor)]
            let resolved = try await client.json(components.url!, userAgent: UserAgent.stashy)
            guard let value = resolved["did"].string else { throw StashyError.notFound }
            did = value
        }
        let uri = "at://\(did)/app.bsky.feed.post/\(reference.rkey)"
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread")!
        components.queryItems = [.init(name: "uri", value: uri), .init(name: "depth", value: "0"), .init(name: "parentHeight", value: "0")]
        let response = try await client.get(components.url!, userAgent: UserAgent.stashy, accept: "application/json")
        if response.status == 400, response.text.contains("NotFound") { throw StashyError.notFound }
        try HTTPClient.check(response)
        let thread = try response.json()["thread"]
        if thread["$type"].string == "app.bsky.feed.defs#blockedPost" { throw StashyError.privateContent }
        if thread["$type"].string == "app.bsky.feed.defs#notFoundPost" { throw StashyError.notFound }
        let post = thread["post"]
        guard post.exists else { throw StashyError.notFound }

        let pds = try? await personalDataServer(for: did, client: client)
        var items: [MediaItem] = []
        let view = post["embed"]
        let record = post["record"]["embed"]
        // A quote post with media keeps both in `recordWithMedia`.
        let mediaView = view["$type"].string == "app.bsky.embed.recordWithMedia#view" ? view["media"] : view
        let mediaRecord = record["$type"].string == "app.bsky.embed.recordWithMedia" ? record["media"] : record

        let images = mediaView["images"].array
        let imageRecords = mediaRecord["images"].array
        for (index, image) in images.enumerated() {
            var variants: [MediaVariant] = []
            let ratio = image["aspectRatio"]
            if let pds, let cid = imageRecords[safe: index]?["image"]["ref"]["$link"].string, let blob = Self.blobURL(pds: pds, did: did, cid: cid) {
                let mime = imageRecords[safe: index]?["image"]["mimeType"].string ?? "image/jpeg"
                variants.append(MediaVariant(delivery: .file(blob), width: ratio["width"].int, height: ratio["height"].int, codec: Extract.codecFamily(mime) == mime ? mime.replacingOccurrences(of: "image/", with: "").uppercased() : nil, container: mime.contains("png") ? "png" : mime.contains("webp") ? "webp" : mime.contains("gif") ? "gif" : "jpg", sizeBytes: imageRecords[safe: index]?["image"]["size"].int64, label: "original upload"))
            }
            if let fullsize = image["fullsize"].url {
                variants.append(Extract.photo(fullsize, width: ratio["width"].int, height: ratio["height"].int, label: "fullsize"))
            }
            guard !variants.isEmpty else { continue }
            // Keep the source's own ranking: the upload first, the CDN copy second.
            items.append(Extract.item(.photo, variants, thumbnail: image["thumb"].url, alt: image["alt"].string))
        }

        if mediaView["$type"].string == "app.bsky.embed.video#view" {
            var variants: [MediaVariant] = []
            let ratio = mediaView["aspectRatio"]
            if let pds, let cid = mediaRecord["video"]["ref"]["$link"].string, let blob = Self.blobURL(pds: pds, did: did, cid: cid) {
                variants.append(MediaVariant(delivery: .file(blob), width: ratio["width"].int, height: ratio["height"].int, codec: "H.264", container: "mp4", sizeBytes: mediaRecord["video"]["size"].int64, label: "original upload"))
            }
            if let playlist = mediaView["playlist"].url {
                variants.append(MediaVariant(delivery: .hls(playlist), width: ratio["width"].int, height: ratio["height"].int, codec: "H.264", container: "mp4", label: "stream"))
            }
            if !variants.isEmpty {
                items.append(Extract.item(.video, variants, thumbnail: mediaView["thumbnail"].url, alt: mediaView["alt"].string))
            }
        }

        // An external link card's picture is worth keeping when nothing else is attached.
        if items.isEmpty, let thumb = mediaView["external"]["thumb"].url {
            items.append(Extract.item(.photo, [Extract.photo(thumb, label: "link card")], alt: mediaView["external"]["title"].string))
        }

        let authorNode = post["author"]
        let author = Author(
            name: authorNode["displayName"].string ?? authorNode["handle"].string ?? "",
            handle: authorNode["handle"].string,
            avatarURL: authorNode["avatar"].url,
            profileURL: authorNode["handle"].string.flatMap { URL(string: "https://bsky.app/profile/\($0)") }
        )
        let canonical = URL(string: "https://bsky.app/profile/\(author.handle ?? did)/post/\(reference.rkey)") ?? url
        return Post(
            platform: .bluesky, sourceURL: url, canonicalURL: canonical, author: author, title: nil,
            text: post["record"]["text"].string ?? "", createdAt: Extract.date(fromISO: post["record"]["createdAt"].string),
            items: items, extractor: "bluesky-atproto.1"
        )
    }

    /// The server that hosts this account's repository, from its DID document.
    private func personalDataServer(for did: String, client: HTTPClient) async throws -> URL {
        let documentURL: URL
        if did.hasPrefix("did:plc:") {
            documentURL = URL(string: "https://plc.directory/\(did)")!
        } else if did.hasPrefix("did:web:") {
            let host = String(did.dropFirst("did:web:".count))
            documentURL = URL(string: "https://\(host)/.well-known/did.json")!
        } else {
            throw StashyError.unsupportedLink
        }
        let document = try await client.json(documentURL, userAgent: UserAgent.stashy)
        for service in document["service"].array where service["id"].string == "#atproto_pds" || service["type"].string == "AtprotoPersonalDataServer" {
            if let endpoint = service["serviceEndpoint"].url { return endpoint }
        }
        throw StashyError.sourceChanged
    }

    private static func blobURL(pds: URL, did: String, cid: String) -> URL? {
        var components = URLComponents(url: pds.appendingPathComponent("xrpc/com.atproto.sync.getBlob"), resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "did", value: did), .init(name: "cid", value: cid)]
        return components?.url
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
