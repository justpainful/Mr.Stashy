import Foundation
import Testing
@testable import MrStashy

/// Exercises each shipped adapter against a real public post and records what it observed.
///
/// This suite is inert unless `LIVE_PLATFORM_CONTRACTS=1` reaches the *test process*. It used
/// to be set on `xcodebuild` instead, which never forwards it, so the "live" contracts ran
/// entirely offline and the verification pipeline could not fail. `scripts/platform_contracts.sh`
/// now injects it through `TEST_RUNNER_`, which is the mechanism that works.
///
/// A result recorded from a data centre is a diagnostic, not a verdict about a phone: several
/// sources answer differently there. That is why a run only ever records what it saw, and why
/// `PlatformCapabilityRegistry` lets evidence narrow the shipped baseline but never widen it.
struct LivePlatformContractTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LIVE_PLATFORM_CONTRACTS"] == "1"
    }

    private static var resultsDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PLATFORM_CONTRACT_RESULTS"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PlatformContractResults", isDirectory: true)
    }

    /// One representative public post per source. Each is a long-lived, widely referenced item
    /// rather than something that will vanish next week.
    private static let subjects: [(platform: Platform, address: String)] = [
        (.tikTok, "https://www.tiktok.com/@scout2015/video/6718335390845095173"),
        (.instagram, "https://www.instagram.com/p/CyXaQ8Ir4sh/"),
        (.x, "https://x.com/jack/status/20"),
        (.reddit, "https://www.reddit.com/r/aww/comments/2ff9dr/tucked_in/"),
        // A post that actually carries a picture. The first fixture chosen here was text-only,
        // so the contract recorded "no media was found" — a true statement about that post and
        // no test of the adapter at all.
        (.bluesky, "https://bsky.app/profile/bsky.app/post/3mmwmla3xph26"),
        // The previous pin had been deleted; Pinterest's own oEmbed reported it gone, so the
        // contract was measuring a 404 rather than the adapter.
        (.pinterest, "https://www.pinterest.com/pin/117304765294445383/"),
        (.snapchat, "https://www.snapchat.com/spotlight"),
        (.kick, "https://kick.com/xqc"),
        (.threads, "https://www.threads.net/@zuck"),
        // A post, not a blog index — and on the host Tumblr actually serves to a reader.
        (.tumblr, "https://www.tumblr.com/zoesupreme/824038832417767424"),
        (.imgur, "https://imgur.com/gallery/oCsGh"),
        (.youTube, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    ]

    @Test(arguments: subjects.map(\.platform))
    func recordsWhatEachSourceActuallyServes(platform: Platform) async throws {
        try #require(Self.isEnabled, "Live contracts are disabled; set LIVE_PLATFORM_CONTRACTS=1 to run them.")
        let address = try #require(Self.subjects.first { $0.platform == platform }?.address)
        let source = try #require(URL(string: address))
        let registry = ResolverRegistry()

        var status: SupportStatus
        var evidence: String
        do {
            let post = try await registry.resolve(source)
            let usable = post.media.compactMap(\.highestVariant)
            if usable.isEmpty {
                status = .failing
                evidence = "Resolved the post but it exposed no usable file address."
            } else {
                status = .passing
                evidence = "Resolved \(usable.count) confirmed media item(s) through \(post.resolverVersion)."
                if !post.warnings.isEmpty {
                    status = .limited
                    evidence += " Reported: \(post.warnings.joined(separator: " "))"
                }
            }
        } catch let error as ResolverError {
            status = error == .authenticationRequired || error == .contentPrivate ? .blocked : .failing
            evidence = "Resolution reported: \(error.localizedDescription)"
        } catch {
            status = .failing
            evidence = "Resolution failed: \(error.localizedDescription)"
        }

        try Self.record(platform: platform, status: status, evidence: evidence)

        // The run's purpose is to produce evidence, so an unavailable third party does not fail
        // the suite. `scripts/validate_support_report.py` is what decides whether the recorded
        // matrix is good enough to release.
        #expect(!evidence.isEmpty)
    }

    private static func record(platform: Platform, status: SupportStatus, evidence: String) throws {
        let directory = resultsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: String] = [
            "platform": platform.rawValue,
            "status": status.rawValue,
            "evidence": SensitiveLog.redact(evidence)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("\(platform.rawValue).json"), options: .atomic)
    }
}
