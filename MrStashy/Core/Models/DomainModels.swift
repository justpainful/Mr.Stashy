import Foundation

enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case tikTok, instagram, x, pinterest, snapchat, kick, threads, tumblr, imgur, youTube, discord, directMedia
    var id: String { rawValue }
    var titleKey: String { "platform.\(rawValue)" }
    var hostnames: [String] {
        switch self {
        case .tikTok: ["tiktok.com"]
        case .instagram: ["instagram.com"]
        case .x: ["x.com", "twitter.com"]
        case .pinterest: ["pinterest.com", "pin.it"]
        case .snapchat: ["snapchat.com"]
        case .kick: ["kick.com"]
        case .threads: ["threads.net"]
        case .tumblr: ["tumblr.com"]
        case .imgur: ["imgur.com"]
        case .youTube: ["youtube.com", "youtu.be"]
        case .discord: ["discord.com"]
        case .directMedia: []
        }
    }
}

enum MediaType: String, Codable, CaseIterable, Sendable, Identifiable {
    case photo, video, audio, gif
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .gif: "rectangle.on.rectangle.angled"
        }
    }
}

enum SourceCleanliness: String, Codable, Sendable {
    case original, clean, watermarked, unknown
    var titleKey: String { "source.\(rawValue)" }
}

struct ResolvedAuthor: Codable, Hashable, Sendable {
    var platformID: String?
    var displayName: String
    var username: String?
    var avatarURL: URL?
    var profileURL: URL?
    var badges: [String]
}

struct MediaVariant: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var url: URL
    var headers: [String: String]
    var expirationDate: Date?
    var width: Int?
    var height: Int?
    var bitrate: Int?
    var fps: Double?
    var isHDR: Bool?
    var codec: String?
    var container: String?
    var hasSeparateAudio: Bool
    var estimatedBytes: Int64?
    var qualityLabel: String
    var cleanliness: SourceCleanliness
}

struct ResolvedMedia: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var orderIndex: Int
    var type: MediaType
    var thumbnailURL: URL?
    var variants: [MediaVariant]
    var width: Int?
    var height: Int?
    var duration: TimeInterval?
    var altText: String?

    var highestVariant: MediaVariant? {
        variants.max { lhs, rhs in
            let lhsPixels = (lhs.width ?? 0) * (lhs.height ?? 0)
            let rhsPixels = (rhs.width ?? 0) * (rhs.height ?? 0)
            if lhsPixels != rhsPixels { return lhsPixels < rhsPixels }
            let lhsBitrate = lhs.bitrate ?? 0
            let rhsBitrate = rhs.bitrate ?? 0
            if lhsBitrate != rhsBitrate { return lhsBitrate < rhsBitrate }
            return (lhs.estimatedBytes ?? 0) < (rhs.estimatedBytes ?? 0)
        }
    }
}

struct ResolvedPost: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var platform: Platform
    var originalURL: URL
    var canonicalURL: URL
    var author: ResolvedAuthor
    var text: String
    var createdAt: Date?
    var fetchedAt: Date
    var quotedPost: QuotedPost?
    var media: [ResolvedMedia]
    var resolverVersion: String
    var warnings: [String]
}

struct QuotedPost: Codable, Hashable, Sendable {
    var author: ResolvedAuthor
    var text: String
    var canonicalURL: URL?
}

enum ResolverError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL, unsupportedURL, contentNotFound, contentPrivate, authenticationRequired, rateLimited, platformChanged, mediaMissing, qualityUnavailable, expiredMediaURL, networkFailure, invalidResponse, verificationFailure

    var errorDescription: String? { L10n.value("resolver.error.\(self)") }
}

struct UserVisibleError: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct QueueItem: Identifiable, Equatable {
    enum SaveMode: String { case fullPost, mediaOnly }
    enum Stage: Equatable {
        case resolving, analyzing, downloading, waiting, paused, merging, verifying, creatingArchive, savingToPhotos, completed, cancelled, failed(String)
        var titleKey: String {
            switch self {
            case .failed: "queue.stage.failed"
            case .cancelled: "queue.stage.cancelled"
            default: "queue.stage.\(String(describing: self))"
            }
        }
    }
    var id = UUID()
    var post: ResolvedPost
    var selectedMediaIDs: Set<UUID>
    var mode: SaveMode
    var stage: Stage = .creatingArchive
    var progress: Double = 0
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64? = nil
    var bytesPerSecond: Double = 0
    var estimatedTimeRemaining: TimeInterval?
}

struct ArchivedPostSummary: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var platform: Platform
    var author: String
    var text: String
    var mediaCount: Int
    var savedAt: Date
    var localFolderName: String
}

/// A lightweight media-library row. The archive manifest remains the source of truth; this
/// value only makes every downloaded file independently browsable and links it back to post.
struct ArchivedMediaSummary: Hashable, Identifiable, Sendable {
    var id: UUID { mediaID }
    var archiveID: UUID
    var mediaID: UUID
    var orderIndex: Int
    var type: MediaType
    var platform: Platform
    var author: String
    var savedAt: Date
    var localFilename: String?
    var fileSize: Int64?
    var isHDR: Bool?
}

struct ArchiveManifest: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var archiveID: UUID
    var platform: Platform
    var canonicalURL: URL
    var sourceURL: URL
    var author: ResolvedAuthor
    var text: String
    var timestamp: Date?
    var quotedPost: QuotedPost?
    var orderedMedia: [ArchivedMediaRecord]
    var resolverVersion: String
    var savedAt: Date
}

struct ArchivedMediaRecord: Codable, Sendable {
    var mediaID: UUID
    var orderIndex: Int
    var type: MediaType
    var originalURL: URL
    var localFilename: String?
    var checksumSHA256: String?
    var variant: MediaVariant?
}

enum SupportStatus: String, Codable, Sendable { case passing, failing, blocked, notShipped }
struct PlatformCapability: Codable, Hashable, Sendable, Identifiable {
    var platform: Platform
    var status: SupportStatus
    var evidence: String
    var id: Platform { platform }
}
