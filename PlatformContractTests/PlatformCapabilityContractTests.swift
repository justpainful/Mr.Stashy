import Foundation
import Testing
@testable import MrStashy

struct PlatformCapabilityContractTests {
    @Test func capabilityMatrixCoversEveryPlatformWithoutDuplicates() {
        let matrix = PlatformCapabilityRegistry.all
        #expect(Set(matrix.map(\.platform)) == Set(Platform.allCases))
        #expect(Set(matrix.map(\.platform)).count == matrix.count)
    }

    /// The Catch screen is built from this registry, so a source may only appear there when a
    /// resolver can actually handle its addresses. This is the tie the interface previously
    /// lacked: it advertised eleven sources while the matrix said none of them shipped.
    @Test func everyUsableSourceHasAResolverThatCanHandleIt() throws {
        let registry = ResolverRegistry(prober: PassthroughMediaProber())
        for capability in PlatformCapabilityRegistry.usable {
            let sample = try #require(URL(string: Self.sampleURL(for: capability.platform)))
            let canonical = try URLCanonicalizer.canonicalize(sample)
            #expect(
                registry.resolver(for: canonical)?.platform == capability.platform,
                "\(capability.platform.rawValue) is advertised but no resolver claims its addresses"
            )
        }
    }

    /// Discord has no adapter, so it must never be offered.
    @Test func sourcesWithoutAnAdapterAreNeverOffered() {
        let offered = PlatformCapabilityRegistry.usable.map(\.platform)
        #expect(!offered.contains(.discord))
        #expect(PlatformCapabilityRegistry.capability(for: .discord)?.status == .blocked)
    }

    /// A source may only be called fully supported when it can yield the post's own media.
    /// One that can only yield a cover image has to say `limited` instead.
    @Test func coverOnlySourcesAreNotAdvertisedAsFullySupported() {
        for platform in [Platform.youTube, .snapchat] {
            #expect(PlatformCapabilityRegistry.capability(for: platform)?.status != .passing)
        }
    }

    /// Live evidence may narrow the shipped baseline but must never widen it.
    @Test func contractEvidenceCanOnlyNarrowTheBaseline() {
        for capability in PlatformCapabilityRegistry.all {
            guard let evidence = PlatformContractEvidence.all.first(where: { $0.platform == capability.platform }) else { continue }
            if evidence.status == .failing || evidence.status == .blocked {
                #expect(capability.status == evidence.status)
            }
        }
    }

    @Test func directMediaContractPreservesCanonicalSource() async throws {
        let source = try #require(URL(string: "https://cdn.example.com/clip.mp4?utm_source=fixture"))
        let post = try await ResolverRegistry(prober: PassthroughMediaProber()).resolve(source)

        #expect(post.platform == .directMedia)
        #expect(post.canonicalURL.absoluteString == "https://cdn.example.com/clip.mp4")
        #expect(post.media.count == 1)
        #expect(post.media.first?.type == .video)
        #expect(post.media.first?.orderIndex == 0)
    }

    private static func sampleURL(for platform: Platform) -> String {
        switch platform {
        case .tikTok: "https://www.tiktok.com/@stashy/video/1234567890"
        case .instagram: "https://www.instagram.com/p/public-fixture/"
        case .x: "https://x.com/stashy/status/1234567890"
        case .reddit: "https://www.reddit.com/r/stashy/comments/abc123/public_fixture/"
        case .bluesky: "https://bsky.app/profile/stashy.bsky.social/post/abc123"
        case .pinterest: "https://www.pinterest.com/pin/1234567890/"
        case .snapchat: "https://www.snapchat.com/spotlight/public-fixture"
        case .kick: "https://kick.com/stashy?clip=clip_public"
        case .threads: "https://www.threads.net/@stashy/post/public-fixture"
        case .tumblr: "https://stashy.tumblr.com/post/1234567890/public-fixture"
        case .imgur: "https://imgur.com/abcdef"
        case .youTube: "https://www.youtube.com/watch?v=publicfixture"
        case .discord: "https://discord.com/channels/1/2/3"
        case .directMedia: "https://cdn.example.com/clip.mp4"
        }
    }
}
