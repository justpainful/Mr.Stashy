import Foundation

enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case tikTok, instagram, x, pinterest, snapchat, kick, threads, tumblr, imgur, youTube, discord, directMedia
    var id: String { rawValue }
    var titleKey: String { "platform.\(rawValue)" }
    var hostnames: [String] {
        switch self {
        case .tikTok: ["tiktok.com"]
        case .instagram: ["instagram.com", "instagr.am", "ig.me"]
        case .x: ["x.com", "twitter.com"]
        // Pinterest publishes country domains, and `pin.it` is its own share shortener.
        case .pinterest: ["pinterest.com", "pin.it", "pinterest.co.uk", "pinterest.ca", "pinterest.fr", "pinterest.de"]
        case .snapchat: ["snapchat.com", "story.snapchat.com"]
        case .kick: ["kick.com"]
        // Threads moved to `threads.com`; links shared before the move still use `threads.net`.
        case .threads: ["threads.net", "threads.com"]
        case .tumblr: ["tumblr.com", "tmblr.co"]
        case .imgur: ["imgur.com", "imgur.io"]
        case .youTube: ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        case .discord: ["discord.com", "discord.gg"]
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

    var safeArchiveCopy: MediaVariant {
        var copy = self
        copy.headers = headers.filter { key, _ in
            let normalized = key.lowercased()
            return normalized != "authorization" && normalized != "cookie" && normalized != "set-cookie" &&
                !normalized.contains("token") && !normalized.contains("api-key")
        }
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.query = nil
            components.fragment = nil
            copy.url = components.url ?? url
        }
        return copy
    }
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

    /// What the person can actually do about it. A failure that only states what went wrong
    /// leaves the screen a dead end.
    var recoveryKey: String { "resolver.recovery.\(self)" }
}

struct UserVisibleError: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct QueueItem: Identifiable, Equatable {
    enum SaveMode: String, Codable, Sendable { case fullPost, mediaOnly }
    enum Stage: Equatable {
        case resolving, analyzing, downloading, waiting, paused, merging, verifying, creatingArchive, savingToPhotos, completed, cancelled, failed(String)
        var titleKey: String {
            switch self {
            case .failed: "queue.stage.failed"
            case .cancelled: "queue.stage.cancelled"
            default: "queue.stage.\(String(describing: self))"
            }
        }

        /// A stage the queue will not leave on its own, so its row can be cleared.
        var isFinished: Bool {
            switch self {
            case .completed, .cancelled, .failed: true
            default: false
            }
        }

        var canRetry: Bool {
            switch self {
            case .failed, .cancelled: true
            default: false
            }
        }

        /// The message a failure carries, so a caller can present it in full rather than
        /// squeezing it into a status caption.
        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }
    var id = UUID()
    var post: ResolvedPost
    var selectedMediaIDs: Set<UUID>
    var mode: SaveMode
    var quality: UserSettings.Quality = .original
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

/// What Stashy can honestly claim for one source.
/// `limited` exists because "works" and "does not work" are both wrong for a source that
/// publishes a post's text and cover image but never publishes its video file. Collapsing that
/// into either answer is what previously made a working capture look like a failure.
enum SupportStatus: String, Codable, Sendable, CaseIterable {
    case passing, limited, needsCredential, failing, blocked, notShipped

    var isUsable: Bool {
        switch self {
        case .passing, .limited, .needsCredential: true
        case .failing, .blocked, .notShipped: false
        }
    }
}

struct PlatformCapability: Codable, Hashable, Sendable, Identifiable {
    var platform: Platform
    var status: SupportStatus
    var evidence: String
    /// The credential a person can supply themselves to lift this source to a full capture.
    var unlockCredential: ResolverCredential?
    var id: Platform { platform }

    init(platform: Platform, status: SupportStatus, evidence: String, unlockCredential: ResolverCredential? = nil) {
        self.platform = platform
        self.status = status
        self.evidence = evidence
        self.unlockCredential = unlockCredential
    }
}
