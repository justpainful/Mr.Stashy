import Foundation
import Testing
@testable import MrStashy

struct PlatformCapabilityContractTests {
    @Test func capabilityMatrixCoversEveryPlatformWithoutDuplicates() {
        let matrix = PlatformCapabilityRegistry.all
        #expect(Set(matrix.map(\.platform)) == Set(Platform.allCases))
        #expect(Set(matrix.map(\.platform)).count == matrix.count)
    }

    @Test func onlyVerifiedDirectMediaIsAdvertisedAsShipped() {
        let shipped = PlatformCapabilityRegistry.shipped.map(\.platform)
        #expect(shipped == [.directMedia])
        #expect(PlatformCapabilityRegistry.all.first(where: { $0.platform == .discord })?.status == .blocked)
    }

    @Test func directMediaContractPreservesCanonicalSource() async throws {
        let source = try #require(URL(string: "https://cdn.example.com/clip.mp4?utm_source=fixture"))
        let post = try await ResolverRegistry().resolve(source)

        #expect(post.platform == .directMedia)
        #expect(post.canonicalURL.absoluteString == "https://cdn.example.com/clip.mp4")
        #expect(post.media.count == 1)
        #expect(post.media.first?.type == .video)
        #expect(post.media.first?.orderIndex == 0)
    }
}
