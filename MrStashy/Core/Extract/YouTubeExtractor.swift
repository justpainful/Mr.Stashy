import Foundation

/// Reads the player response YouTube serves its own iOS app. That response lists every
/// stream with a direct address: progressive MP4 (video+audio up to 720p) and adaptive
/// video-only / audio-only streams up to 4K, which Stashy muxes on the device.
struct YouTubeExtractor: Extractor {
    let platform: Platform = .youTube

    private struct Client {
        let name: String
        let id: String
        let version: String
        let userAgent: String
        let context: [String: Any]
    }

    private static let ios = Client(
        name: "IOS", id: "5", version: "20.10.4",
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        context: ["clientName": "IOS", "clientVersion": "20.10.4", "deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82", "hl": "en", "gl": "US", "utcOffsetMinutes": 0]
    )

    private static let androidVR = Client(
        name: "ANDROID_VR", id: "28", version: "1.62.27",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        context: ["clientName": "ANDROID_VR", "clientVersion": "1.62.27", "deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L", "hl": "en", "gl": "US"]
    )

    static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let parts = LinkParser.pathComponents(url)
        if host == "youtu.be" { return parts.first.flatMap(valid) }
        if let v = LinkParser.query(url, "v"), let id = valid(v) { return id }
        if let index = parts.firstIndex(where: { ["shorts", "embed", "live", "v", "e"].contains($0) }), parts.count > index + 1 {
            return valid(parts[index + 1])
        }
        return nil
    }

    private static func valid(_ candidate: String) -> String? {
        let id = String(candidate.prefix(11))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return id.count == 11 && id.unicodeScalars.allSatisfy { allowed.contains($0) } ? id : nil
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let id = Self.videoID(from: url) else { throw StashyError.unsupportedLink }
        var lastError: StashyError = .sourceChanged
        for api in [Self.ios, Self.androidVR] {
            do {
                let response = try await player(id: id, client: client, api: api)
                return try build(response, id: id, url: url, api: api)
            } catch let error as StashyError where error == .sourceChanged || error == .noMedia {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func player(id: String, client: HTTPClient, api: Client) async throws -> JSONValue {
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        let body: [String: Any] = [
            "context": ["client": api.context],
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        let headers = ["X-YouTube-Client-Name": api.id, "X-YouTube-Client-Version": api.version, "Origin": "https://www.youtube.com"]
        let response = try await client.postJSON(endpoint, json: body, userAgent: api.userAgent, headers: headers)
        try HTTPClient.check(response)
        return try response.json()
    }

    private func build(_ root: JSONValue, id: String, url: URL, api: Client) throws -> Post {
        let status = root["playabilityStatus"]
        switch status["status"].string {
        case "OK", nil: break
        case "LOGIN_REQUIRED": throw StashyError.loginRequired
        case "ERROR":
            let reason = status["reason"].string?.lowercased() ?? ""
            throw reason.contains("private") ? StashyError.privateContent : StashyError.notFound
        case "UNPLAYABLE":
            let reason = status["reason"].string?.lowercased() ?? ""
            if reason.contains("reload") || reason.contains("player") { throw StashyError.sourceChanged }
            throw StashyError.privateContent
        case "LIVE_STREAM_OFFLINE": throw StashyError.noMedia
        default: throw StashyError.sourceChanged
        }

        let details = root["videoDetails"]
        let streaming = root["streamingData"]
        let downloadHeaders = ["User-Agent": api.userAgent]
        var variants: [MediaVariant] = []

        // Audio-only streams, best first. Only AAC in MP4 muxes cleanly on the device.
        let audioFormats = streaming["adaptiveFormats"].array.filter { format in
            let mime = format["mimeType"].string ?? ""
            return mime.hasPrefix("audio/mp4") && format["url"].exists
        }.sorted { ($0["bitrate"].int ?? 0) > ($1["bitrate"].int ?? 0) }
        let bestAudio = audioFormats.first

        for format in streaming["adaptiveFormats"].array {
            let mime = format["mimeType"].string ?? ""
            guard mime.hasPrefix("video/mp4"), let videoURL = format["url"].url, let audio = bestAudio, let audioURL = audio["url"].url else { continue }
            let codec = Extract.codecFamily(mime)
            // VP9 and H.265 never appear in mp4 here; H.264 and AV1 do. AV1 above 1080p is the
            // only way to get 4K as MP4, and the assembler refuses it on a device that cannot
            // decode it, so it is offered but ranked honestly.
            guard codec == "H.264" || codec == "AV1" else { continue }
            let size = (format["contentLength"].int64 ?? 0) + (audio["contentLength"].int64 ?? 0)
            var variant = MediaVariant(
                delivery: .muxed(video: videoURL, audio: audioURL),
                width: format["width"].int, height: format["height"].int,
                bitrate: format["bitrate"].int, fps: format["fps"].double,
                codec: codec, container: "mp4", sizeBytes: size > 0 ? size : nil,
                label: format["qualityLabel"].string ?? "adaptive",
                headers: downloadHeaders, expiresAt: SignedURL.expiry(of: videoURL)
            )
            if variant.label.isEmpty { variant.label = "adaptive" }
            variants.append(variant)
        }

        for format in streaming["formats"].array {
            guard let fileURL = format["url"].url else { continue }
            let mime = format["mimeType"].string ?? ""
            variants.append(MediaVariant(
                delivery: .file(fileURL),
                width: format["width"].int, height: format["height"].int,
                bitrate: format["bitrate"].int, fps: format["fps"].double,
                codec: Extract.codecFamily(mime), container: "mp4",
                sizeBytes: format["contentLength"].int64,
                label: (format["qualityLabel"].string ?? "progressive") + " (single file)",
                headers: downloadHeaders, expiresAt: SignedURL.expiry(of: fileURL)
            ))
        }

        // Prefer the single-file progressive stream when it matches the best muxed resolution:
        // same pixels, no assembly step.
        let ranked = ExtractorRegistry.rank(variants)
        guard !ranked.isEmpty else {
            if streaming["hlsManifestUrl"].exists { throw StashyError.noMedia }
            throw StashyError.sourceChanged
        }

        let thumbnails = details["thumbnail"]["thumbnails"].array
        let thumbnail = thumbnails.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }?["url"].url
            ?? URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
        let duration = details["lengthSeconds"].double
        let video = MediaItem(index: 0, kind: .video, variants: ranked, thumbnailURL: thumbnail, duration: duration, altText: details["title"].string)

        // The cover image is the second item so a person can keep it with the video.
        var items = [video]
        if let cover = thumbnail {
            let best = thumbnails.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
            items.append(Extract.item(.photo, [Extract.photo(cover, width: best?["width"].int, height: best?["height"].int, label: "cover")]))
        }

        let channelID = details["channelId"].string
        let author = Author(
            name: details["author"].string ?? "",
            handle: nil,
            avatarURL: nil,
            profileURL: channelID.flatMap { URL(string: "https://www.youtube.com/channel/\($0)") }
        )
        var notes: [String] = []
        if let best = ranked.first, best.codec == "AV1" {
            notes.append(L10n.value("note.av1"))
        }
        if details["isLiveContent"].bool == true, streaming["formats"].array.isEmpty, variants.isEmpty {
            notes.append(L10n.value("note.live"))
        }
        let canonical = URL(string: "https://www.youtube.com/watch?v=\(id)") ?? url
        return Post(
            platform: .youTube, sourceURL: url, canonicalURL: canonical, author: author,
            title: details["title"].string, text: details["shortDescription"].string ?? "",
            createdAt: Extract.date(fromISO: root["microformat"]["playerMicroformatRenderer"]["publishDate"].string),
            items: items, notes: notes, extractor: "youtube-innertube.\(api.name.lowercased()).1"
        )
    }
}
