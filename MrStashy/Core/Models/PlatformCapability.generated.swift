import Foundation

// Generated from Artifacts/PlatformSupportReport.json by scripts/generate_capability_registry.py.
enum PlatformCapabilityRegistry {
    static let all: [PlatformCapability] = [
        .init(platform: .directMedia, status: .passing, evidence: "DirectMediaResolver deterministic contract passed in PlatformContractTests."),
        .init(platform: .tikTok, status: .passing, evidence: "TikTokResolver contract passed with video/slideshow media resolution."),
        .init(platform: .instagram, status: .passing, evidence: "InstagramResolver contract passed with carousel/Reel media extraction."),
        .init(platform: .x, status: .passing, evidence: "XResolver contract passed with multi-media and official API support."),
        .init(platform: .pinterest, status: .passing, evidence: "PinterestResolver contract passed with OpenGraph image/video pin extraction."),
        .init(platform: .snapchat, status: .passing, evidence: "SnapchatResolver contract passed with public Spotlight media extraction."),
        .init(platform: .kick, status: .passing, evidence: "KickResolver contract passed with public clip/VOD media extraction."),
        .init(platform: .threads, status: .passing, evidence: "ThreadsResolver contract passed with multi-media post extraction."),
        .init(platform: .tumblr, status: .passing, evidence: "TumblrResolver contract passed with reblog and multi-photo extraction."),
        .init(platform: .imgur, status: .passing, evidence: "ImgurResolver contract passed with gallery and GIF/video extraction."),
        .init(platform: .youTube, status: .notShipped, evidence: "YouTube intentionally omitted from v0.1 release per release contract."),
        .init(platform: .discord, status: .blocked, evidence: "Bot-only, permission-scoped integration is not configured")
    ]

    static var shipped: [PlatformCapability] { all.filter { $0.status == .passing } }
}
