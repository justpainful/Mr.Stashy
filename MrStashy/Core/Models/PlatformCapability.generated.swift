import Foundation

// Generated from Artifacts/PlatformSupportReport.json by scripts/generate_capability_registry.py.
// This file records only what a live contract run observed. It never widens what a shipped
// adapter claims: PlatformCapabilityRegistry uses it to narrow the in-code baseline, so a
// missing or failing contract can demote a source but can never promote one.
enum PlatformContractEvidence {
    static let all: [PlatformCapability] = [
        .init(platform: .directMedia, status: .passing, evidence: "Deterministic DirectMediaResolver contract passed; no source-platform scraping is involved."),
        .init(platform: .tikTok, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .instagram, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .x, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .reddit, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .bluesky, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .pinterest, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .snapchat, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .kick, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .threads, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .tumblr, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .imgur, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .youTube, status: .notShipped, evidence: "support.evidence.noLiveResult"),
        .init(platform: .discord, status: .blocked, evidence: "support.evidence.discord")
    ]
}
