import Foundation

// Generated from Artifacts/PlatformSupportReport.json by scripts/generate_capability_registry.py.
// This file records only what a live contract run observed. It never widens what a shipped
// adapter claims: PlatformCapabilityRegistry uses it to narrow the in-code baseline, so a
// missing or failing contract can demote a source but can never promote one.
enum PlatformContractEvidence {
    static let all: [PlatformCapability] = [
        .init(platform: .directMedia, status: .passing, evidence: "Deterministic DirectMediaResolver contract passed; no source-platform scraping is involved."),
        .init(platform: .tikTok, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .instagram, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .x, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .reddit, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .bluesky, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .pinterest, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .snapchat, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .kick, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .threads, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .tumblr, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .imgur, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .youTube, status: .notShipped, evidence: "No complete live contract result was produced for this revision."),
        .init(platform: .discord, status: .blocked, evidence: "Bot-only, permission-scoped integration is not configured")
    ]
}
