import Foundation

// Generated from Artifacts/PlatformSupportReport.json by scripts/generate_capability_registry.py.
enum PlatformCapabilityRegistry {
    static let all: [PlatformCapability] = [
        .init(platform: .directMedia, status: .passing, evidence: "Deterministic DirectMediaResolver contract passed; no source-platform scraping is involved."),
        .init(platform: .tikTok, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .instagram, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .x, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .pinterest, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .snapchat, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .kick, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .threads, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .tumblr, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .imgur, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .youTube, status: .notShipped, evidence: "YouTube intentionally omitted from v0.1 release per release contract."),
        .init(platform: .discord, status: .blocked, evidence: "Bot-only, permission-scoped integration is not configured")
    ]

    static var shipped: [PlatformCapability] { all.filter { $0.status == .passing } }
}
