import Foundation
import Testing
@testable import MrStashy

/// Tumblr publishes no usable API, so its adapter reads the addresses a post page actually
/// serves. These pin the shapes that page uses — including the two that silently produced
/// nothing: an extension Tumblr invented, and a pattern that failed to compile at all.
struct TumblrMediaTests {
    private static let page = """
    <html><body>
    <img src="https://64.media.tumblr.com/2696294694d6019bf2509ed408280a97/4250680dfc901594-05/s640x960/37b26ddb943b6b15038d7105374e9cfe6e8f637f.pnj">
    <img srcset="https://64.media.tumblr.com/2696294694d6019bf2509ed408280a97/4250680dfc901594-05/s2048x3072/65806cdb943b6b15038d7105374e9cfe6e8f637f.pnj 2048w">
    <img src="https://64.media.tumblr.com/9ebdb780bc187ca029ebe3e15e8df596/ee642df10ad6acd0-ba/s540x810/b4e8e5d457dc9b2ba58c00f8bcbbe9fe3a393a9c.jpg">
    <img src="https://64.media.tumblr.com/28ab4fa1d2ba4e3e12cf48908096dafc/c1a0936ecf90574f-c0/s512x512u_c1/0d2273cecfd6b1c5d968871234567890abcdef12.pnj">
    <img src="https://64.media.tumblr.com/28ab4fa1d2ba4e3e12cf48908096dafc/c1a0936ecf90574f-c0/s64x64/276f3b5dd1c5d96887aabbccddeeff0011223344.pnj">
    </body></html>
    """

    @Test func tumblrKeepsTheLargestRenditionOfEachImage() throws {
        let candidates = TumblrMedia.candidates(in: Self.page)

        // Two real pictures: the 640-wide copy is dropped in favour of the 2048-wide one.
        #expect(candidates.count == 2)
        #expect(candidates[0].url.absoluteString.contains("s2048x3072"))
        #expect(candidates[0].width == 2_048)
        #expect(candidates[1].url.absoluteString.contains("s540x810"))
    }

    /// Tumblr serves most images as `.pnj`, an extension it invented. A pattern that only knew
    /// the ordinary ones matched nothing on a real post, which read as "this post has no media".
    @Test func tumblrsOwnImageExtensionIsRecognised() {
        let candidates = TumblrMedia.candidates(in: Self.page)
        #expect(candidates.contains { $0.url.pathExtension == "pnj" })
    }

    /// An avatar is site furniture. Tumblr marks its centre-cropped square renditions with a
    /// `u_c` suffix, and a 512-point one otherwise passes any size threshold worth having.
    @Test func avatarsAndThumbnailsAreNotMistakenForThePost() {
        let candidates = TumblrMedia.candidates(in: Self.page)
        #expect(!candidates.contains { $0.url.absoluteString.contains("u_c1") })
        #expect(!candidates.contains { $0.url.absoluteString.contains("s64x64") })
    }

    /// A blog subdomain answers a reader with 403; the same post is served from `www`. Without
    /// this rewrite every shared Tumblr address is a dead end before anything can read it.
    @Test func blogSubdomainAddressesAreRewrittenToTheHostTumblrServes() throws {
        let shared = try #require(URL(string: "https://8pxl.tumblr.com/post/796604952242978816/my-2026-calendars"))
        let canonical = try URLCanonicalizer.canonicalize(shared)
        #expect(canonical.absoluteString == "https://tumblr.com/8pxl/796604952242978816")
    }

    @Test func anAddressThatIsAlreadyOnTheServingHostIsLeftAlone() throws {
        let direct = try #require(URL(string: "https://www.tumblr.com/zoesupreme/824038832417767424"))
        let canonical = try URLCanonicalizer.canonicalize(direct)
        #expect(canonical.absoluteString == "https://tumblr.com/zoesupreme/824038832417767424")
    }

    /// Pinterest stopped publishing an `orig` rendition; every pin resolved to nothing until the
    /// decoder read whichever sizes a pin does publish.
    @Test func pinterestOriginalIsDerivedFromAPublishedRendition() throws {
        let rendition = try #require(URL(string: "https://i.pinimg.com/564x/c2/ce/73/c2ce7381d4b8cf41f2517bf094106988.jpg"))
        let original = try #require(PinterestOriginalAddress.make(from: rendition))
        #expect(original.absoluteString == "https://i.pinimg.com/originals/c2/ce/73/c2ce7381d4b8cf41f2517bf094106988.jpg")

        // An address already pointing at the original is left alone.
        #expect(PinterestOriginalAddress.make(from: original) == nil)
    }
}
