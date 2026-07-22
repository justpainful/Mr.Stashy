import Foundation
import Testing
@testable import MrStashy

struct PriorityPlatformResolverTests {
    @Test(arguments: [Platform.tikTok, .instagram, .x])
    func priorityResolversPreserveSourceExposedMixedMediaOrder(platform: Platform) async throws {
        let source = try #require(URL(string: sourceURL(for: platform)))
        let client = FixtureResolverClient(html: """
        <meta property="og:url" content="\(source.absoluteString)">
        <meta property="og:title" content="Public fixture">
        <meta property="og:site_name" content="\(platform.rawValue)">
        <meta property="og:image" content="https://cdn.example.com/first.jpg">
        <meta property="og:video" content="https://cdn.example.com/second.mp4">
        <meta property="og:image" content="https://cdn.example.com/third.gif">
        """)
        let request = ResolveRequest(originalURL: source, canonicalURL: source)
        let resolver: any PlatformResolver
        switch platform {
        case .tikTok: resolver = TikTokResolver(client: client)
        case .instagram: resolver = InstagramResolver(client: client)
        case .x: resolver = XResolver(client: client)
        default: throw ResolverError.unsupportedURL
        }
        let post = try await resolver.resolve(request)

        #expect(post.platform == platform)
        #expect(post.media.map(\.orderIndex) == [0, 1, 2])
        #expect(post.media.map(\.type) == [.photo, .video, .gif])
        #expect(post.media.map { $0.highestVariant?.url.absoluteString } == [
            "https://cdn.example.com/first.jpg",
            "https://cdn.example.com/second.mp4",
            "https://cdn.example.com/third.gif"
        ])
    }

    @Test func sourceWithoutExposedMediaFailsInsteadOfSavingAThumbnailOnlyPost() async throws {
        let source = try #require(URL(string: "https://www.instagram.com/p/public-fixture/"))
        let request = ResolveRequest(originalURL: source, canonicalURL: source)

        await #expect(throws: ResolverError.self) {
            try await InstagramResolver(client: FixtureResolverClient(html: "<meta property=\"og:title\" content=\"No media\">"))
                .resolve(request)
        }
    }

    @Test func xResolverUsesAnOwnerSuppliedBearerTokenToPreserveEveryAPIExposedMediaItem() async throws {
        let source = try #require(URL(string: "https://x.com/stashy/status/1234567890"))
        let client = FixtureDataResolverClient(json: """
        {
          "data": {
            "id": "1234567890",
            "text": "A mixed-media post",
            "author_id": "42",
            "created_at": "2026-07-22T01:00:00.000Z",
            "attachments": { "media_keys": ["3_photo", "3_video"] }
          },
          "includes": {
            "users": [{ "id": "42", "name": "Stashy", "username": "stashy", "profile_image_url": "https://cdn.example.com/avatar.jpg" }],
            "media": [
              { "media_key": "3_photo", "type": "photo", "url": "https://cdn.example.com/photo.jpg", "width": 2048, "height": 1365 },
              { "media_key": "3_video", "type": "video", "preview_image_url": "https://cdn.example.com/video.jpg", "width": 1920, "height": 1080, "duration_ms": 12000,
                "variants": [
                  { "url": "https://cdn.example.com/video-360.mp4", "content_type": "video/mp4", "bit_rate": 832000 },
                  { "url": "https://cdn.example.com/video-720.mp4", "content_type": "video/mp4", "bit_rate": 2176000 }
                ]
              }
            ]
          }
        }
        """)
        let post = try await XResolver(client: client, credentials: FixedResolverCredentials(values: [.xBearerToken: "owner-supplied-token"]))
            .resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.author.username == "stashy")
        #expect(post.media.map(\.type) == [.photo, .video])
        #expect(post.media[1].highestVariant?.url.absoluteString == "https://cdn.example.com/video-720.mp4")
        #expect(post.media[1].duration == 12)
    }

    private func sourceURL(for platform: Platform) -> String {
        switch platform {
        case .tikTok: "https://www.tiktok.com/@stashy/video/1234567890"
        case .instagram: "https://www.instagram.com/p/public-fixture/"
        case .x: "https://x.com/stashy/status/1234567890"
        default: "https://example.com"
        }
    }
}

private struct FixtureResolverClient: ResolverHTTPClient {
    let html: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        return (Data(html.utf8), response)
    }
}

private struct FixtureDataResolverClient: ResolverHTTPClient {
    let json: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }
}

private struct FixedResolverCredentials: ResolverCredentialProvider {
    let values: [ResolverCredential: String]

    func value(for credential: ResolverCredential) -> String? {
        values[credential]
    }
}
