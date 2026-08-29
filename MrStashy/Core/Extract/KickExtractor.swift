import Foundation

/// Kick publishes clips and past broadcasts as HLS streams. Stashy downloads every segment
/// and rewrites them into one MP4, so a clip is a real file, not a poster frame.
struct KickExtractor: Extractor {
    let platform: Platform = .kick

    private static let headers = ["User-Agent": UserAgent.desktopChrome, "Referer": "https://kick.com/", "Accept": "application/json"]

    enum Target {
        case clip(String)
        case video(String)
        case channel(String)
    }

    static func target(for url: URL) -> Target? {
        let parts = LinkParser.pathComponents(url)
        if let clip = LinkParser.query(url, "clip") { return .clip(clip) }
        if let index = parts.firstIndex(of: "clips"), parts.count > index + 1 { return .clip(parts[index + 1]) }
        if let index = parts.firstIndex(where: { $0 == "video" || $0 == "videos" }), parts.count > index + 1 { return .video(parts[index + 1]) }
        if let first = parts.first, parts.count == 1 { return .channel(first) }
        return nil
    }

    func extract(_ url: URL, client: HTTPClient, credentials: CredentialSource) async throws -> Post {
        guard let target = Self.target(for: url) else { throw StashyError.unsupportedLink }
        switch target {
        case .clip(let id):
            let root = try await client.json(URL(string: "https://kick.com/api/v2/clips/\(id)")!, userAgent: UserAgent.desktopChrome, headers: Self.headers)
            let clip = root["clip"].exists ? root["clip"] : root
            guard let playlist = clip["video_url"].url ?? clip["clip_url"].url else { throw StashyError.noMedia }
            let channel = clip["channel"]
            let author = Author(
                name: channel["username"].string ?? channel["slug"].string ?? "",
                handle: channel["slug"].string,
                avatarURL: channel["profile_picture"].url,
                profileURL: channel["slug"].string.flatMap { URL(string: "https://kick.com/\($0)") }
            )
            let variant = MediaVariant(delivery: .hls(playlist), codec: "H.264", container: "mp4", label: "clip stream")
            let item = Extract.item(.video, [variant], thumbnail: clip["thumbnail_url"].url, duration: clip["duration"].double, alt: clip["title"].string)
            let canonical = URL(string: "https://kick.com/\(author.handle ?? "")/clips/\(id)") ?? url
            return Post(platform: .kick, sourceURL: url, canonicalURL: canonical, author: author, title: clip["title"].string, text: "", createdAt: Extract.date(fromISO: clip["created_at"].string), items: [item], extractor: "kick-clip.1")

        case .video(let id):
            let root = try await client.json(URL(string: "https://kick.com/api/v1/video/\(id)")!, userAgent: UserAgent.desktopChrome, headers: Self.headers)
            guard let source = root["source"].url else { throw StashyError.noMedia }
            let live = root["livestream"]
            let channel = live["channel"]
            let author = Author(
                name: channel["user"]["username"].string ?? channel["slug"].string ?? "",
                handle: channel["slug"].string,
                avatarURL: channel["user"]["profile_pic"].url,
                profileURL: channel["slug"].string.flatMap { URL(string: "https://kick.com/\($0)") }
            )
            let variant = MediaVariant(delivery: .hls(source), codec: "H.264", container: "mp4", label: "broadcast stream")
            let item = Extract.item(.video, [variant], thumbnail: live["thumbnail"].url, duration: live["duration"].double.map { $0 / 1000 }, alt: live["session_title"].string)
            return Post(platform: .kick, sourceURL: url, canonicalURL: URL(string: "https://kick.com/video/\(id)") ?? url, author: author, title: live["session_title"].string, text: "", createdAt: Extract.date(fromISO: live["created_at"].string), items: [item], notes: [L10n.value("note.kickBroadcast")], extractor: "kick-video.1")

        case .channel:
            // A live channel page has no finished file to keep.
            throw StashyError.noMedia
        }
    }
}
