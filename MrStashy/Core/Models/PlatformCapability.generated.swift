import Foundation

// Generated from Artifacts/PlatformSupportReport.json by scripts/generate_capability_registry.py.
enum PlatformCapabilityRegistry {
    static let all: [PlatformCapability] = [
        .init(platform: .directMedia, status: .passing, evidence: "DirectMediaResolver deterministic contract passed in PlatformContractTests."),
        .init(platform: .tikTok, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .instagram, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .x, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .pinterest, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .snapchat, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .kick, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .threads, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .tumblr, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .imgur, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .youTube, status: .notShipped, evidence: "No verified resolver is registered in this build."),
        .init(platform: .discord, status: .blocked, evidence: "Bot-only, permission-scoped integration is not configured")
    ]

    static var shipped: [PlatformCapability] { all.filter { $0.status == .passing } }
}
