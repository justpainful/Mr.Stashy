import Foundation
import Testing
@testable import MrStashy

/// The two sources read through their own public APIs. Each test pins the exact payload shape the
/// platform publishes, so a change on their side fails here rather than silently degrading a
/// capture to a share card.
struct PublicAPIResolverTests {
    // MARK: - Reddit

    @Test func redditGalleryKeepsEveryImageInTheAuthorsOrder() async throws {
        let source = try #require(URL(string: "https://www.reddit.com/r/stashy/comments/abc123/three_pictures/"))
        let client = RoutedFixtureClient(routes: [
            "reddit.com/comments/abc123.json": Self.redditGalleryPayload
        ])

        let post = try await RedditResolver(client: client, prober: PassthroughMediaProber())
            .resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.platform == .reddit)
        #expect(post.author.displayName == "r/stashy")
        #expect(post.author.username == "sample_author")
        #expect(post.media.map(\.orderIndex) == [0, 1, 2])
        #expect(post.media.map { $0.highestVariant?.url.absoluteString } == [
            "https://i.redd.it/one.jpg",
            "https://i.redd.it/two.jpg",
            "https://i.redd.it/three.jpg"
        ])
    }

    @Test func redditHostedVideoIsSavedAndItsMissingSoundIsStated() async throws {
        let source = try #require(URL(string: "https://www.reddit.com/r/stashy/comments/vid001/a_clip/"))
        let client = RoutedFixtureClient(routes: [
            "reddit.com/comments/vid001.json": Self.redditVideoPayload
        ])

        let post = try await RedditResolver(client: client, prober: PassthroughMediaProber())
            .resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.media.map(\.type) == [.video])
        #expect(post.media.first?.highestVariant?.url.absoluteString == "https://v.redd.it/xyz/DASH_720.mp4")
        #expect(post.media.first?.duration == 34)
        // The saved file genuinely has no audio track, and the capture has to say so rather than
        // leave a person thinking playback is broken.
        #expect(post.warnings.contains(L10n.value("resolver.warning.redditSilentVideo")))
    }

    @Test func redditPostTakenDownIsReportedAsPrivateRatherThanEmpty() async throws {
        let source = try #require(URL(string: "https://www.reddit.com/r/stashy/comments/gone01/removed/"))
        let client = RoutedFixtureClient(routes: [
            "reddit.com/comments/gone01.json": """
            [{"data":{"children":[{"data":{"title":"Removed","removed_by_category":"moderator"}}]}}]
            """
        ])

        await #expect(throws: ResolverError.contentPrivate) {
            try await RedditResolver(client: client, prober: PassthroughMediaProber())
                .resolve(ResolveRequest(originalURL: source, canonicalURL: source))
        }
    }

    @Test(arguments: [
        ("https://www.reddit.com/r/stashy/comments/abc123/slug/", "abc123"),
        ("https://reddit.com/comments/def456", "def456"),
        ("https://redd.it/ghi789", "ghi789")
    ])
    func redditIdentifiersAreReadFromEveryShapeOfPublicLink(address: String, expected: String) throws {
        let url = try #require(URL(string: address))
        #expect(RedditResolver.postID(in: url) == expected)
    }

    // MARK: - Bluesky

    @Test func blueskyResolvesTheHandleThenKeepsEveryAttachedPictureAtFullSize() async throws {
        let source = try #require(URL(string: "https://bsky.app/profile/stashy.bsky.social/post/3abc"))
        let client = RoutedFixtureClient(routes: [
            "com.atproto.identity.resolveHandle": #"{"did":"did:plc:sample"}"#,
            "app.bsky.feed.getPostThread": Self.blueskyImagePayload
        ])

        let post = try await BlueskyResolver(client: client, prober: PassthroughMediaProber())
            .resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.platform == .bluesky)
        #expect(post.author.username == "stashy.bsky.social")
        #expect(post.text == "Two pictures.")
        #expect(post.media.map(\.type) == [.photo, .photo])
        #expect(post.media.map { $0.highestVariant?.url.absoluteString } == [
            "https://cdn.bsky.app/img/feed_fullsize/one@jpeg",
            "https://cdn.bsky.app/img/feed_fullsize/two@jpeg"
        ])
        #expect(post.media.first?.altText == "First picture")
    }

    @Test func blueskyVideoIsSavedAsItsPosterAndLabelledAsAStream() async throws {
        let source = try #require(URL(string: "https://bsky.app/profile/did:plc:sample/post/3xyz"))
        let client = RoutedFixtureClient(routes: [
            "app.bsky.feed.getPostThread": Self.blueskyVideoPayload
        ])

        let post = try await BlueskyResolver(client: client, prober: PassthroughMediaProber())
            .resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.media.map(\.type) == [.photo])
        #expect(post.warnings.contains(L10n.value("resolver.warning.adaptiveStream")))
    }

    @Test func blueskyPostReferenceIsReadFromAProfileLink() throws {
        let url = try #require(URL(string: "https://bsky.app/profile/name.bsky.social/post/3l6o"))
        let reference = try #require(BlueskyResolver.reference(in: url))
        #expect(reference.handle == "name.bsky.social")
        #expect(reference.recordKey == "3l6o")
    }

    // MARK: - Payloads

    private static let redditGalleryPayload = """
    [{"data":{"children":[{"data":{
      "title":"Three pictures","author":"sample_author","subreddit":"stashy",
      "created_utc":1700000000,"is_gallery":true,
      "gallery_data":{"items":[{"media_id":"a1"},{"media_id":"a2"},{"media_id":"a3"}]},
      "media_metadata":{
        "a1":{"s":{"u":"https://i.redd.it/one.jpg","x":1200,"y":800}},
        "a2":{"s":{"u":"https://i.redd.it/two.jpg","x":1200,"y":800}},
        "a3":{"s":{"u":"https://i.redd.it/three.jpg","x":1200,"y":800}}
      }
    }}]}}]
    """

    private static let redditVideoPayload = """
    [{"data":{"children":[{"data":{
      "title":"A clip","author":"sample_author","subreddit":"stashy","created_utc":1700000000,
      "media":{"reddit_video":{"fallback_url":"https://v.redd.it/xyz/DASH_720.mp4",
        "width":720,"height":1280,"duration":34,"is_gif":false}}
    }}]}}]
    """

    private static let blueskyImagePayload = """
    {"thread":{"post":{
      "author":{"did":"did:plc:sample","handle":"stashy.bsky.social","displayName":"Stashy"},
      "record":{"text":"Two pictures.","createdAt":"2024-10-01T12:00:00.000Z"},
      "embed":{"$type":"app.bsky.embed.images#view","images":[
        {"fullsize":"https://cdn.bsky.app/img/feed_fullsize/one@jpeg","alt":"First picture","aspectRatio":{"width":1000,"height":750}},
        {"fullsize":"https://cdn.bsky.app/img/feed_fullsize/two@jpeg","alt":"Second picture","aspectRatio":{"width":1000,"height":750}}
      ]}
    }}}
    """

    private static let blueskyVideoPayload = """
    {"thread":{"post":{
      "author":{"did":"did:plc:sample","handle":"stashy.bsky.social","displayName":"Stashy"},
      "record":{"text":"A clip.","createdAt":"2024-10-01T12:00:00.000Z"},
      "embed":{"$type":"app.bsky.embed.video#view",
        "playlist":"https://video.bsky.app/watch/did/abc/playlist.m3u8",
        "thumbnail":"https://video.bsky.app/watch/did/abc/thumbnail.jpg"}
    }}}
    """
}

/// Answers each request with the fixture whose key appears in the address, so a resolver that
/// makes several calls is exercised end to end rather than handed one body for everything.
private struct RoutedFixtureClient: ResolverHTTPClient {
    let routes: [String: String]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let address = url.absoluteString
        guard let body = routes.first(where: { address.contains($0.key) })?.value else {
            let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), missing)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}
