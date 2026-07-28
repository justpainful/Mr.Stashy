import Foundation

/// What each shipped adapter can actually do, and what it cannot.
///
/// This baseline is written next to the resolvers it describes, so it changes when their
/// behaviour changes. A live contract run can only ever *narrow* it: `PlatformContractEvidence`
/// is generated from a real run and takes precedence when it reports a source as failing or
/// blocked. The point is that the app never advertises a capture it cannot perform, and never
/// hides one it can.
enum PlatformCapabilityRegistry {
    static let baseline: [PlatformCapability] = [
        .init(
            platform: .directMedia,
            status: .passing,
            evidence: "A direct media address is confirmed to serve media before it is offered, then checksummed on the way into the archive."
        ),
        .init(
            platform: .x,
            status: .passing,
            evidence: "Reads the public post payload that X publishes for embedded posts, keeping every photo and the highest-bitrate video the post exposes, in order.",
            unlockCredential: .xBearerToken
        ),
        .init(
            platform: .imgur,
            status: .passing,
            evidence: "Resolves the public asset address for the post identifier and confirms the host serves it before saving.",
            unlockCredential: .imgurClientID
        ),
        .init(
            platform: .tikTok,
            status: .limited,
            evidence: "Saves the playable file when the public page publishes one. When it does not, the cover image is saved and the capture is labelled as cover-only rather than presented as the video.",
            unlockCredential: .tikTokAccessToken
        ),
        .init(
            platform: .pinterest,
            status: .limited,
            evidence: "Reads the pin's own public widget payload for the original-size image or video rendition. Private and secret boards are not readable.",
            unlockCredential: .pinterestAccessToken
        ),
        .init(
            platform: .kick,
            status: .limited,
            evidence: "Reads Kick's public clip endpoint. Clips are published as adaptive streams, which are saved as the stream address plus the clip thumbnail."
        ),
        .init(
            platform: .tumblr,
            status: .limited,
            evidence: "Saves the media a public post publishes in its preview metadata. Posts behind a blog's content screen are not readable.",
            unlockCredential: .tumblrAPIKey
        ),
        .init(
            platform: .snapchat,
            status: .limited,
            evidence: "Public Spotlight and Story links expose a preview image. Snapchat publishes no downloadable video address for a signed-out reader."
        ),
        .init(
            platform: .youTube,
            status: .limited,
            evidence: "Saves the title, channel, and cover image that YouTube publishes through its own oEmbed endpoint. YouTube publishes no file address, so the video stream is not part of the capture."
        ),
        .init(
            platform: .instagram,
            status: .needsCredential,
            evidence: "A public post that still publishes preview metadata is saved. Instagram answers most signed-out requests with a login page, which Stashy reports as needing access rather than as an empty post.",
            unlockCredential: .instagramAccessToken
        ),
        .init(
            platform: .threads,
            status: .needsCredential,
            evidence: "Threads redirects signed-out readers to a login page, so only posts that still publish preview metadata can be saved.",
            unlockCredential: .threadsAccessToken
        ),
        .init(
            platform: .discord,
            status: .blocked,
            evidence: "Discord support is bot-only and permission-scoped, and no bot token is configured. Stashy never automates a personal Discord account."
        )
    ]

    /// The baseline, narrowed by whatever a real contract run proved. Evidence can demote a
    /// source or add detail; it can never promote one past what the adapter is built to do.
    static let all: [PlatformCapability] = {
        let evidenceByPlatform = Dictionary(
            PlatformContractEvidence.all.map { ($0.platform, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return baseline.map { capability in
            guard let evidence = evidenceByPlatform[capability.platform] else { return capability }
            switch evidence.status {
            case .failing, .blocked:
                var narrowed = capability
                narrowed.status = evidence.status
                narrowed.evidence = evidence.evidence
                return narrowed
            case .passing, .limited, .needsCredential, .notShipped:
                return capability
            }
        }
    }()

    /// Sources a person can actually use right now, best first. `Catch` is built from this, so
    /// the picker can never advertise a source the app has no adapter for.
    static var usable: [PlatformCapability] {
        all.filter { $0.status.isUsable }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status { return rank(lhs.status) < rank(rhs.status) }
                return L10n.value(lhs.platform.titleKey) < L10n.value(rhs.platform.titleKey)
            }
    }

    static var shipped: [PlatformCapability] { all.filter { $0.status == .passing } }

    static func capability(for platform: Platform) -> PlatformCapability? {
        all.first { $0.platform == platform }
    }

    private static func rank(_ status: SupportStatus) -> Int {
        switch status {
        case .passing: 0
        case .limited: 1
        case .needsCredential: 2
        case .failing: 3
        case .blocked: 4
        case .notShipped: 5
        }
    }
}

extension SupportStatus {
    var titleKey: String { "support.\(rawValue)" }
}
