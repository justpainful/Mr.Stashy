import Foundation
import Testing
@testable import MrStashy

struct URLCanonicalizerTests {
    @Test func canonicalizationNormalizesHostAndTrackingParameters() throws {
        let source = try #require(URL(string: "http://www.example.com/post?id=42&utm_source=newsletter&fbclid=tracking#comments"))

        let result = try URLCanonicalizer.canonicalize(source)

        #expect(result.absoluteString == "https://example.com/post?id=42")
    }

    @Test func directMediaResolverBuildsAnOriginalVariant() async throws {
        let source = try #require(URL(string: "https://cdn.example.com/clip.mp4"))
        let request = ResolveRequest(originalURL: source, canonicalURL: source)

        let post = try await DirectMediaResolver().resolve(request)

        #expect(post.platform == .directMedia)
        #expect(post.media.count == 1)
        #expect(post.media[0].type == .video)
        #expect(post.media[0].highestVariant?.cleanliness == .original)
    }

    @Test func openGraphParserReadsMetaTagsWithWhitespace() throws {
        let document = OpenGraphDocument(html: """
        <html><head>
          <meta property = \"og:title\" content = \"A public post\">
          <meta property=\"og:image\" content=\"https://cdn.example.com/photo.jpg\">
        </head></html>
        """)

        #expect(document.title == "A public post")
        #expect(document.media.map(\.url) == ["https://cdn.example.com/photo.jpg"])
    }

    @Test func openGraphParserPreservesMixedMediaSourceOrder() {
        let document = OpenGraphDocument(html: """
        <meta property="og:image" content="https://cdn.example.com/first.jpg">
        <meta property="og:video" content="https://cdn.example.com/second.mp4">
        <meta property="og:image" content="https://cdn.example.com/third.jpg">
        """)

        #expect(document.media.map(\.url) == [
            "https://cdn.example.com/first.jpg",
            "https://cdn.example.com/second.mp4",
            "https://cdn.example.com/third.jpg"
        ])
    }
}
