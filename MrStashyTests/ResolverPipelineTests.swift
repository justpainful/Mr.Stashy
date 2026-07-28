import Foundation
import Testing
@testable import MrStashy

/// These cover the behaviours that decide whether a capture is trustworthy: that a candidate is
/// confirmed before it is offered, that a player page is never mistaken for a file, and that a
/// login wall is reported as one rather than as an empty post.
struct ResolverPipelineTests {
    // MARK: - Candidates are confirmed before they are offered

    @Test func anAddressThatDoesNotServeMediaIsDroppedBeforeItCanBeSaved() async throws {
        let source = try #require(URL(string: "https://www.tumblr.com/stashy/1234"))
        let client = FixturePageClient(html: """
        <meta property="og:image" content="https://cdn.example.com/real.jpg">
        <meta property="og:image" content="https://cdn.example.com/gone.jpg">
        """)
        let prober = FixtureProber(rejecting: ["https://cdn.example.com/gone.jpg"])
        let resolver = PublicOpenGraphResolver(platform: .tumblr, client: client, prober: prober)

        let post = try await resolver.resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.media.count == 1)
        #expect(post.media.first?.highestVariant?.url.absoluteString == "https://cdn.example.com/real.jpg")
        #expect(!post.warnings.isEmpty, "dropping part of a post has to be stated, not hidden")
    }

    @Test func aPostWhereNothingIsStillServedFailsRatherThanSavingNothing() async throws {
        let source = try #require(URL(string: "https://www.tumblr.com/stashy/1234"))
        let client = FixturePageClient(html: #"<meta property="og:image" content="https://cdn.example.com/gone.jpg">"#)
        let resolver = PublicOpenGraphResolver(
            platform: .tumblr,
            client: client,
            prober: FixtureProber(rejecting: ["https://cdn.example.com/gone.jpg"])
        )

        await #expect(throws: ResolverError.self) {
            try await resolver.resolve(ResolveRequest(originalURL: source, canonicalURL: source))
        }
    }

    @Test func theServersContentTypeOverridesAMisleadingFileExtension() async throws {
        let source = try #require(URL(string: "https://www.tumblr.com/stashy/1234"))
        let client = FixturePageClient(html: #"<meta property="og:image" content="https://cdn.example.com/asset">"#)
        let prober = FixtureProber(contentTypes: ["https://cdn.example.com/asset": "video/mp4"])
        let resolver = PublicOpenGraphResolver(platform: .tumblr, client: client, prober: prober)

        let post = try await resolver.resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.media.first?.type == .video)
    }

    @Test func aProbedLengthBecomesTheDownloadSizeTheQueueShows() async throws {
        let source = try #require(URL(string: "https://www.tumblr.com/stashy/1234"))
        let client = FixturePageClient(html: #"<meta property="og:video" content="https://cdn.example.com/clip.mp4">"#)
        let prober = FixtureProber(lengths: ["https://cdn.example.com/clip.mp4": 5_242_880])
        let resolver = PublicOpenGraphResolver(platform: .tumblr, client: client, prober: prober)

        let post = try await resolver.resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.media.first?.highestVariant?.estimatedBytes == 5_242_880)
    }

    // MARK: - A player page is not a media file

    @Test func anEmbedPlayerAddressIsNeverOfferedAsSavableMedia() throws {
        let base = try #require(URL(string: "https://www.youtube.com/watch?v=abc"))
        let candidates = PageMediaExtractor.candidates(
            in: """
            <meta property="og:video:url" content="https://www.youtube.com/embed/abc">
            <meta property="og:video:type" content="text/html">
            <meta property="og:image" content="https://i.ytimg.com/vi/abc/hqdefault.jpg">
            """,
            baseURL: base
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.url.absoluteString == "https://i.ytimg.com/vi/abc/hqdefault.jpg")
    }

    @Test func anAdaptiveStreamManifestIsNotTreatedAsAFile() throws {
        let base = try #require(URL(string: "https://kick.com/stashy"))
        let candidates = PageMediaExtractor.candidates(
            in: #"<meta property="og:video" content="https://clips.kick.com/a/playlist.m3u8">"#,
            baseURL: base
        )

        #expect(candidates.isEmpty)
    }

    // MARK: - Reading what the page actually published

    @Test func entityEncodedQueryStringsSurviveIntoAWorkingAddress() {
        let document = OpenGraphDocument(html: #"<meta property="og:image" content="https://cdn.example.com/a.jpg?sig=x&amp;exp=9&amp;id=7">"#)

        #expect(document.media.first?.url == "https://cdn.example.com/a.jpg?sig=x&exp=9&id=7")
    }

    @Test func secureOnlyPagesStillExposeTheirMedia() {
        let document = OpenGraphDocument(html: #"<meta property="og:image:secure_url" content="https://cdn.example.com/secure.jpg">"#)

        #expect(document.media.map(\.url) == ["https://cdn.example.com/secure.jpg"])
    }

    @Test func schemaOrgVideoObjectsAreReadWhenOpenGraphIsAbsent() throws {
        let base = try #require(URL(string: "https://example.com/post"))
        let candidates = JSONLDMediaExtractor.candidates(
            in: """
            <script type="application/ld+json">
            {"@type":"VideoObject","contentUrl":"https://cdn.example.com/v.mp4","duration":"PT1M30S","width":1920,"height":1080}
            </script>
            """,
            baseURL: base
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.url.absoluteString == "https://cdn.example.com/v.mp4")
        #expect(candidates.first?.duration == 90)
        #expect(candidates.first?.width == 1920)
    }

    @Test func inlineVideoElementsAreReadWhenAPagePublishesNoPreviewTags() throws {
        let base = try #require(URL(string: "https://example.com/post"))
        let candidates = PageMediaExtractor.candidates(
            in: #"<article><video src="/media/clip.mp4" controls></video></article>"#,
            baseURL: base
        )

        #expect(candidates.map { $0.url.absoluteString } == ["https://example.com/media/clip.mp4"])
        #expect(candidates.first?.resolvedType == .video)
    }

    @Test func aPageThatOnlyPublishesItsOwnLogoIsFlaggedRatherThanPresentedAsThePost() async throws {
        let source = try #require(URL(string: "https://imgur.com/gallery/xyz"))
        let client = FixturePageClient(html: #"<meta property="og:image" content="https://s.imgur.com/images/logo-1200-630.png">"#)
        let engine = PageResolutionEngine(platform: .imgur, client: client, prober: PassthroughMediaProber())

        let post = try await engine.resolvePage(
            ResolveRequest(originalURL: source, canonicalURL: source),
            resolverVersion: "test"
        )

        #expect(post.warnings.contains { !$0.isEmpty })
    }

    // MARK: - Saying why, not just that it failed

    @Test func aLoginWallIsReportedAsNeedingAccessRatherThanAsAnEmptyPost() throws {
        let requested = try #require(URL(string: "https://www.instagram.com/p/abc/"))
        let landing = try #require(URL(string: "https://www.instagram.com/accounts/login/"))
        let page = FetchedPage(url: landing, html: "<html><body>Please log in to continue</body></html>", profile: .browser)

        #expect(AccessWallDetector.wall(in: page, requested: requested) == .authenticationRequired)
    }

    @Test func aPrivatePostIsDistinguishedFromOneThatNeedsAnAccount() throws {
        let requested = try #require(URL(string: "https://www.instagram.com/p/abc/"))
        let page = FetchedPage(url: requested, html: "<html>This account is private</html>", profile: .browser)

        #expect(AccessWallDetector.wall(in: page, requested: requested) == .contentPrivate)
    }

    @Test func everyResolverErrorOffersSomethingToDoNext() {
        let errors: [ResolverError] = [
            .invalidURL, .unsupportedURL, .contentNotFound, .contentPrivate, .authenticationRequired,
            .rateLimited, .platformChanged, .mediaMissing, .qualityUnavailable, .expiredMediaURL,
            .networkFailure, .invalidResponse, .verificationFailure
        ]
        for error in errors {
            let recovery = L10n.value(error.recoveryKey)
            #expect(recovery != error.recoveryKey, "\(error) has no recovery guidance")
            #expect(error.localizedDescription != "resolver.error.\(error)")
        }
    }

    @Test func transferStatusesMapToDistinctCauses() {
        #expect(DownloadEngine.error(for: 403) == .expiredMediaURL)
        #expect(DownloadEngine.error(for: 404) == .contentNotFound)
        #expect(DownloadEngine.error(for: 429) == .rateLimited)
        #expect(DownloadEngine.error(for: 401) == .authenticationRequired)
    }

    // MARK: - Real payload shapes

    /// The widget endpoint answers with `data` as a bare array. Decoding it as an object made
    /// every pin fall through to the page, which publishes nothing pin-specific.
    @Test func pinterestWidgetPayloadDecodesTheShapeTheEndpointActuallyReturns() async throws {
        let source = try #require(URL(string: "https://www.pinterest.com/pin/99290459813297/"))
        let client = FixtureJSONClient(json: """
        {"status":"success","code":0,"message":"ok","endpoint_name":"v3_pin_info","data":[
          {"id":"99290459813297","description":"A public pin",
           "images":{"orig":{"url":"https://i.pinimg.com/originals/a/b/c.jpg","width":1200,"height":1600}},
           "pinner":{"full_name":"Stashy","username":"stashy"}}
        ]}
        """)
        let resolver = PinterestResolver(client: client, prober: PassthroughMediaProber())

        let post = try await resolver.resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.media.count == 1)
        #expect(post.media.first?.highestVariant?.url.absoluteString == "https://i.pinimg.com/originals/a/b/c.jpg")
        #expect(post.media.first?.width == 1200)
        #expect(post.author.username == "stashy")
        #expect(post.text == "A public pin")
    }

    /// Kick publishes clips as adaptive streams. Archiving the manifest would put a few
    /// kilobytes of playlist text into the archive under the name of the video.
    @Test func kickClipsFallBackToThePosterFrameAndSayWhy() async throws {
        let source = try #require(URL(string: "https://kick.com/stashy?clip=clip_01ABC"))
        let client = FixtureJSONClient(json: """
        {"clip":{"id":"clip_01ABC","title":"A clip","duration":15,
          "clip_url":"https://clips.kick.com/a/playlist.m3u8",
          "video_url":"https://clips.kick.com/a/playlist.m3u8",
          "thumbnail_url":"https://clips.kick.com/a/thumbnail.webp",
          "channel":{"username":"Stashy","slug":"stashy"}}}
        """)
        let resolver = KickResolver(client: client, prober: PassthroughMediaProber())

        let post = try await resolver.resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.media.count == 1)
        #expect(post.media.first?.type == .photo)
        #expect(post.media.first?.highestVariant?.url.absoluteString.hasSuffix("thumbnail.webp") == true)
        #expect(!post.warnings.isEmpty)
    }

    /// The public syndication payload is where X exposes ordered media; the preview tags do not.
    @Test func xSyndicationPayloadKeepsOrderedMediaAndOriginalSizes() async throws {
        let source = try #require(URL(string: "https://x.com/stashy/status/1349129669258448897"))
        let client = FixtureJSONClient(json: """
        {"text":"A public post","created_at":"2021-01-12T23:02:33.000Z",
         "user":{"name":"Stashy","screen_name":"stashy","profile_image_url_https":"https://pbs.twimg.com/a.jpg"},
         "mediaDetails":[
           {"type":"photo","media_url_https":"https://pbs.twimg.com/media/one.jpg","original_info":{"width":960,"height":900}},
           {"type":"video","media_url_https":"https://pbs.twimg.com/media/poster.jpg","original_info":{"width":1280,"height":720},
            "video_info":{"duration_millis":12000,"variants":[
              {"content_type":"video/mp4","url":"https://video.twimg.com/low.mp4","bitrate":832000},
              {"content_type":"video/mp4","url":"https://video.twimg.com/high.mp4","bitrate":2176000},
              {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/stream.m3u8"}]}}
         ]}
        """)
        let resolver = XResolver(client: client, credentials: NoResolverCredentials(), prober: PassthroughMediaProber())

        let post = try await resolver.resolve(ResolveRequest(originalURL: source, canonicalURL: source))

        #expect(post.author.username == "stashy")
        #expect(post.media.map(\.type) == [.photo, .video])
        // The original-size parameter is what makes X return the full image rather than a crop.
        #expect(post.media[0].highestVariant?.url.absoluteString == "https://pbs.twimg.com/media/one.jpg?name=orig")
        // Highest-bitrate progressive file, never the adaptive manifest.
        #expect(post.media[1].highestVariant?.url.absoluteString == "https://video.twimg.com/high.mp4")
        #expect(post.media[1].duration == 12)
    }

    // MARK: - Signed addresses

    @Test func anExpiredSignedAddressIsRecognisedBeforeItIsDownloaded() throws {
        let expired = try #require(URL(string: "https://cdn.example.com/v.mp4?x-expires=1600000000&x-signature=abc"))
        let date = try #require(SignedURLExpiry.date(in: expired))

        #expect(date == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test func anAddressWithoutAnExpiryReportsNone() throws {
        let plain = try #require(URL(string: "https://cdn.example.com/v.mp4?name=orig"))

        #expect(SignedURLExpiry.date(in: plain) == nil)
    }

    // MARK: - Address handling

    @Test func platformIdentifiersInQueryStringsSurviveCanonicalization() throws {
        let watch = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=share&feature=share"))

        let canonical = try URLCanonicalizer.canonicalize(watch)

        #expect(canonical.absoluteString == "https://youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(YouTubeResolver.videoID(in: canonical) == "dQw4w9WgXcQ")
    }

    @Test func shortLinksFromEverySupportedShareSheetAreRecognised() throws {
        for link in [
            "https://t.co/stashy", "https://instagr.am/p/x/", "https://vm.tiktok.com/Z/",
            "https://vt.tiktok.com/Z/", "https://pin.it/abc", "https://youtu.be/abc", "https://tmblr.co/abc"
        ] {
            let url = try #require(URL(string: link))
            #expect(URLCanonicalizer.isPlatformShortLink(url), "\(link) is a share-sheet short link")
        }
    }

    @Test func aPlatformPageIsNotMistakenForADirectFile() throws {
        let page = try #require(URL(string: "https://www.tiktok.com/@a/video/123.mp4"))
        let asset = try #require(URL(string: "https://i.imgur.com/abc.jpeg"))

        #expect(!URLCanonicalizer.isDirectMedia(page))
        #expect(URLCanonicalizer.isDirectMedia(asset))
    }

    @Test func postIdentifiersAreReadFromEverySupportedAddressShape() throws {
        #expect(XResolver.postID(in: try #require(URL(string: "https://x.com/a/status/12345"))) == "12345")
        #expect(XResolver.postID(in: try #require(URL(string: "https://twitter.com/a/status/12345/photo/1"))) == "12345")
        #expect(XResolver.postID(in: try #require(URL(string: "https://x.com/a"))) == nil)
        #expect(PinterestResolver.pinID(in: try #require(URL(string: "https://www.pinterest.com/pin/99290459813297/"))) == "99290459813297")
        #expect(KickResolver.clipID(in: try #require(URL(string: "https://kick.com/xqc?clip=clip_01ABC"))) == "clip_01ABC")
        #expect(YouTubeResolver.videoID(in: try #require(URL(string: "https://youtu.be/dQw4w9WgXcQ"))) == "dQw4w9WgXcQ")
        #expect(YouTubeResolver.videoID(in: try #require(URL(string: "https://www.youtube.com/shorts/abc123"))) == "abc123")
    }

    @Test func pageTextIsDecodedFromTheCharsetTheResponseDeclares() throws {
        let arabic = "منشور عام"
        let data = try #require(arabic.data(using: .utf8))
        let url = try #require(URL(string: "https://example.com"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ))

        #expect(HTMLTextDecoder.text(from: data, response: response) == arabic)
    }

    @Test func aLegacyEncodedPageIsStillReadableInsteadOfBeingRejected() throws {
        let data = try #require("Café".data(using: .isoLatin1))
        let url = try #require(URL(string: "https://example.com"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=iso-8859-1"]
        ))

        #expect(HTMLTextDecoder.text(from: data, response: response) == "Café")
    }
}

// MARK: - Fixtures

private struct FixturePageClient: ResolverHTTPClient {
    let html: String
    var statusCode = 200

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        return (Data(html.utf8), response)
    }
}

private struct FixtureJSONClient: ResolverHTTPClient {
    let json: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }
}

private struct NoResolverCredentials: ResolverCredentialProvider {
    func value(for credential: ResolverCredential) -> String? { nil }
}

private struct FixtureProber: MediaProbing {
    var rejected: Set<String> = []
    var contentTypes: [String: String] = [:]
    var lengths: [String: Int64] = [:]

    init(rejecting: [String] = [], contentTypes: [String: String] = [:], lengths: [String: Int64] = [:]) {
        rejected = Set(rejecting)
        self.contentTypes = contentTypes
        self.lengths = lengths
    }

    func probe(_ url: URL, headers: [String: String], referer: URL?) async -> MediaProbeResult? {
        let key = url.absoluteString
        guard !rejected.contains(key) else { return nil }
        return MediaProbeResult(url: url, contentType: contentTypes[key], contentLength: lengths[key])
    }
}
