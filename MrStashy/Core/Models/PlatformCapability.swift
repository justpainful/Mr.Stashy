import Foundation

/// What each shipped adapter can actually do, and what it cannot.
///
/// This baseline is written next to the resolvers it describes, so it changes when their
/// behaviour changes. A live contract run can only ever *narrow* it: `PlatformContractEvidence`
/// is generated from a real run and takes precedence when it reports a source as failing or
/// blocked. The point is that the app never advertises a capture it cannot perform, and never
/// hides one it can.
///
/// The explanations are localisation keys rather than English prose. They are the longest text
/// in the app and the text that says why a source cannot be captured; leaving them untranslated
/// put a wall of English under every row of an otherwise Arabic screen.
enum PlatformCapabilityRegistry {
    static let baseline: [PlatformCapability] = [
        .init(platform: .directMedia, status: .passing, evidence: "support.evidence.directMedia"),
        .init(platform: .x, status: .passing, evidence: "support.evidence.x"),
        .init(platform: .reddit, status: .passing, evidence: "support.evidence.reddit"),
        .init(platform: .bluesky, status: .passing, evidence: "support.evidence.bluesky"),
        .init(platform: .imgur, status: .passing, evidence: "support.evidence.imgur"),
        .init(platform: .tikTok, status: .limited, evidence: "support.evidence.tikTok"),
        .init(platform: .pinterest, status: .limited, evidence: "support.evidence.pinterest"),
        .init(platform: .kick, status: .limited, evidence: "support.evidence.kick"),
        .init(platform: .tumblr, status: .limited, evidence: "support.evidence.tumblr"),
        .init(platform: .snapchat, status: .limited, evidence: "support.evidence.snapchat"),
        .init(platform: .youTube, status: .limited, evidence: "support.evidence.youTube"),
        .init(platform: .instagram, status: .limited, evidence: "support.evidence.instagram"),
        .init(platform: .threads, status: .limited, evidence: "support.evidence.threads"),
        .init(platform: .discord, status: .blocked, evidence: "support.evidence.discord")
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
                if L10n.localizedIfPresent(evidence.evidenceSource) != nil {
                    // The run reported a sentence Stashy authored, so it is translated.
                    narrowed.evidenceSource = evidence.evidenceSource
                } else {
                    // Per-revision diagnostic prose. It is shown after the translated
                    // explanation, never instead of it.
                    narrowed.liveDiagnostic = evidence.evidenceSource
                }
                return narrowed
            case .notShipped:
                // No live contract completed for this revision. Calling a source Verified on the
                // strength of a hand-written sentence is exactly what the support screen exists
                // to prevent, so an unproven claim is demoted to partial and says why. It is
                // never demoted to `.notShipped` itself: that would strip every source from the
                // capture picker over a missing test run rather than a missing capability.
                //
                // The disclaimer is a flag, not baked-in text: this list is built once at
                // launch, and resolving the sentence here would freeze it in whichever language
                // happened to be active then.
                var narrowed = capability
                if narrowed.status == .passing { narrowed.status = .limited }
                narrowed.isUnverified = true
                return narrowed
            case .passing, .limited, .needsCredential:
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
