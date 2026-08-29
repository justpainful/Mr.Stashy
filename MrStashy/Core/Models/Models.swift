import Foundation

// MARK: - Platforms

enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case tikTok, youTube, instagram, threads, x, reddit, bluesky, pinterest, snapchat, kick, tumblr, imgur, discord, web

    var id: String { rawValue }
    var titleKey: String { "platform.\(rawValue)" }

    /// Host suffixes that belong to this source. Matching is suffix-based so `m.`, `vm.`,
    /// `old.` and country domains all land on the same extractor.
    var hosts: [String] {
        switch self {
        case .tikTok: ["tiktok.com"]
        case .youTube: ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        case .instagram: ["instagram.com", "instagr.am", "ig.me"]
        case .threads: ["threads.net", "threads.com"]
        case .x: ["x.com", "twitter.com", "t.co"]
        case .reddit: ["reddit.com", "redd.it", "reddit.app.link"]
        case .bluesky: ["bsky.app", "bsky.social"]
        case .pinterest: ["pinterest.com", "pin.it", "pinterest.co.uk", "pinterest.ca", "pinterest.fr", "pinterest.de", "pinterest.es", "pinterest.it", "pinterest.jp", "pinterest.com.au"]
        case .snapchat: ["snapchat.com"]
        case .kick: ["kick.com"]
        case .tumblr: ["tumblr.com", "tmblr.co"]
        case .imgur: ["imgur.com", "imgur.io"]
        case .discord: ["discord.com", "discordapp.com", "discord.gg"]
        case .web: []
        }
    }

    /// Sources shown on the Catch screen, in the order people actually use them.
    static let featured: [Platform] = [.tikTok, .youTube, .instagram, .x, .reddit, .threads, .bluesky, .pinterest, .snapchat, .kick, .tumblr, .imgur, .discord]

    var systemImage: String {
        switch self {
        case .tikTok: "music.note"
        case .youTube: "play.rectangle.fill"
        case .instagram: "camera.fill"
        case .threads: "at"
        case .x: "xmark"
        case .reddit: "bubble.left.and.bubble.right.fill"
        case .bluesky: "butterfly"
        case .pinterest: "pin.fill"
        case .snapchat: "bolt.fill"
        case .kick: "dot.radiowaves.left.and.right"
        case .tumblr: "text.alignleft"
        case .imgur: "photo.on.rectangle"
        case .discord: "gamecontroller.fill"
        case .web: "globe"
        }
    }
}

// MARK: - Media

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo, video, gif, audio

    var titleKey: String { "media.\(rawValue)" }
    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .video: "play.rectangle"
        case .gif: "photo.stack"
        case .audio: "waveform"
        }
    }

    /// The container Stashy writes for this kind when the source gives no better answer.
    var defaultExtension: String {
        switch self {
        case .photo: "jpg"
        case .video: "mp4"
        case .gif: "gif"
        case .audio: "m4a"
        }
    }
}

/// How the bytes of one variant are obtained. A source that publishes a single file is the
/// simple case; YouTube and Reddit publish video and audio separately, and Kick publishes HLS
/// segments. All three end up as one playable file on the device.
enum MediaDelivery: Codable, Hashable, Sendable {
    case file(URL)
    case muxed(video: URL, audio: URL)
    case hls(URL)

    var primaryURL: URL {
        switch self {
        case .file(let url), .hls(let url): url
        case .muxed(let video, _): video
        }
    }

    var needsAssembly: Bool {
        if case .file = self { return false }
        return true
    }
}

struct MediaVariant: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var delivery: MediaDelivery
    var width: Int?
    var height: Int?
    var bitrate: Int?
    var fps: Double?
    /// Short codec family: "H.264", "H.265", "AV1", "VP9", "AAC", "JPEG", "PNG", "WebP", "GIF".
    var codec: String?
    /// File extension the variant will be written with.
    var container: String
    var sizeBytes: Int64?
    /// What the source called it: "1080p", "orig", "normal_720_0"…
    var label: String
    var headers: [String: String] = [:]
    /// Signed CDN links expire; the queue re-resolves when this has passed.
    var expiresAt: Date?

    var pixels: Int { (width ?? 0) * (height ?? 0) }

    /// Fits into the size column of a spec line: "1080p", "4K", "2048×1536".
    var resolutionLabel: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let short = min(width, height)
        let long = max(width, height)
        if long >= 3800 { return "4K" }
        if long >= 2500 { return "1440p" }
        if short >= 1080 || long >= 1900 { return "1080p" }
        if short >= 720 || long >= 1280 { return "720p" }
        if short >= 480 { return "480p" }
        return "\(width)×\(height)"
    }

    /// A copy safe to write into a manifest: no auth headers, no signed query strings.
    var archivable: MediaVariant {
        var copy = self
        copy.headers = [:]
        return copy
    }
}

struct MediaItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var index: Int
    var kind: MediaKind
    /// Best first. The downloader walks this list until one variant actually arrives.
    var variants: [MediaVariant]
    var thumbnailURL: URL?
    var duration: TimeInterval?
    var altText: String?

    var best: MediaVariant? { variants.first }
}

struct Author: Codable, Hashable, Sendable {
    var name: String
    var handle: String?
    var avatarURL: URL?
    var profileURL: URL?
    var isVerified = false

    var display: String { name.isEmpty ? (handle.map { "@\($0)" } ?? "") : name }
}

struct Post: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var platform: Platform
    var sourceURL: URL
    var canonicalURL: URL
    var author: Author
    var title: String?
    var text: String
    var createdAt: Date?
    var fetchedAt: Date = .now
    var items: [MediaItem]
    /// Honest caveats the person sees before saving ("Source serves 720p at most").
    var notes: [String] = []
    var extractor: String

    var hasVideo: Bool { items.contains { $0.kind == .video } }
    var photoCount: Int { items.filter { $0.kind == .photo || $0.kind == .gif }.count }
}

// MARK: - Errors

enum StashyError: Error, Equatable, Sendable, LocalizedError {
    case invalidLink
    case unsupportedLink
    case notFound
    case loginRequired
    case privateContent
    case rateLimited
    case blocked
    case noMedia
    case sourceChanged
    case network
    case expired
    case assemblyFailed
    case verificationFailed
    case storage
    case cancelled

    var key: String {
        switch self {
        case .invalidLink: "invalidLink"
        case .unsupportedLink: "unsupportedLink"
        case .notFound: "notFound"
        case .loginRequired: "loginRequired"
        case .privateContent: "privateContent"
        case .rateLimited: "rateLimited"
        case .blocked: "blocked"
        case .noMedia: "noMedia"
        case .sourceChanged: "sourceChanged"
        case .network: "network"
        case .expired: "expired"
        case .assemblyFailed: "assemblyFailed"
        case .verificationFailed: "verificationFailed"
        case .storage: "storage"
        case .cancelled: "cancelled"
        }
    }

    var errorDescription: String? { L10n.value("error.\(key)") }
    var recovery: String { L10n.value("error.\(key).fix") }

    static func from(_ error: Error) -> StashyError {
        if let known = error as? StashyError { return known }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return .cancelled }
            return .network
        }
        return .network
    }
}

// MARK: - Queue

struct SaveRequest: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var post: Post
    var selectedItemIDs: Set<UUID>
    var quality: QualityPreference
    var saveToPhotos: Bool
    var createdAt: Date = .now
}

enum QualityPreference: String, Codable, CaseIterable, Sendable {
    /// The largest variant the source serves, including 4K AV1 when the device can play it.
    case best
    /// Caps video at 1080p and prefers H.264, the most compatible choice.
    case upTo1080p
    /// Smallest variant that is still a real file.
    case dataSaver

    var titleKey: String { "quality.\(rawValue)" }
}

enum SaveStage: Codable, Hashable, Sendable {
    case queued, preparing, downloading, assembling, verifying, savingToPhotos, done, failed(String), cancelled

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        default: false
        }
    }

    var titleKey: String {
        switch self {
        case .queued: "stage.queued"
        case .preparing: "stage.preparing"
        case .downloading: "stage.downloading"
        case .assembling: "stage.assembling"
        case .verifying: "stage.verifying"
        case .savingToPhotos: "stage.savingToPhotos"
        case .done: "stage.done"
        case .failed: "stage.failed"
        case .cancelled: "stage.cancelled"
        }
    }
}

struct SaveJob: Identifiable, Hashable, Sendable {
    var id: UUID { request.id }
    var request: SaveRequest
    var stage: SaveStage = .queued
    var progress: Double = 0
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64?
    var bytesPerSecond: Double = 0
    var currentItem: Int = 0
    var savedCount: Int = 0
    var archiveID: UUID?

    var itemCount: Int { request.selectedItemIDs.count }
}

// MARK: - Archive

struct ArchivedFile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var index: Int
    var kind: MediaKind
    var filename: String
    var sizeBytes: Int64
    var sha256: String
    var width: Int?
    var height: Int?
    var duration: TimeInterval?
    var codec: String?
    var label: String
    var altText: String?
    var sourceURL: URL
}

struct ArchiveManifest: Codable, Sendable {
    static let schemaVersion = 2
    var schema: Int = schemaVersion
    var id: UUID
    var platform: Platform
    var sourceURL: URL
    var canonicalURL: URL
    var author: Author
    var title: String?
    var text: String
    var createdAt: Date?
    var savedAt: Date
    var files: [ArchivedFile]
    var extractor: String
    var notes: [String]
    /// Items the source listed that never arrived, with the reason.
    var missing: [String]
}

/// The row the library shows. Built from the manifest; the manifest stays the truth.
struct ArchiveSummary: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var platform: Platform
    var authorName: String
    var authorHandle: String?
    var title: String?
    var text: String
    var savedAt: Date
    var createdAt: Date?
    var fileCount: Int
    var videoCount: Int
    var photoCount: Int
    var totalBytes: Int64
    var coverFilename: String?
    var coverKind: MediaKind?
    var folder: String
    var isPinned = false
    var collectionIDs: [UUID] = []

    var headline: String {
        if let title, !title.isEmpty { return title }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? authorName : trimmed
    }
}

struct Collection: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = .now
}

// MARK: - Coding

extension JSONEncoder {
    static let stashy: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let stashy: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
