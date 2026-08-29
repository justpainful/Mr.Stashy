import XCTest
@testable import MrStashy

final class LinkParserTests: XCTestCase {
    func testPlatformDetection() {
        let cases: [(String, Platform)] = [
            ("https://www.tiktok.com/@scout2015/video/6718335390845095173", .tikTok),
            ("https://vm.tiktok.com/ZMabc/", .tikTok),
            ("https://youtu.be/dQw4w9WgXcQ", .youTube),
            ("https://m.youtube.com/watch?v=dQw4w9WgXcQ", .youTube),
            ("https://www.instagram.com/reel/CyXaQ8Ir4sh/", .instagram),
            ("https://www.threads.com/@zuck/post/DLJhXeAMr5O", .threads),
            ("https://x.com/jack/status/20", .x),
            ("https://twitter.com/jack/status/20", .x),
            ("https://old.reddit.com/r/aww/comments/2ff9dr/tucked_in/", .reddit),
            ("https://bsky.app/profile/bsky.app/post/3mmwmla3xph26", .bluesky),
            ("https://pin.it/abc", .pinterest),
            ("https://www.snapchat.com/spotlight/W7_EDlXWTBiXAEEniNoMPwAAYY2Vmanp6dmx6AZ4eWdT_AZ4eWdSdAAAAAw", .snapchat),
            ("https://kick.com/xqc/clips/clip_01HXYQYPV0BZ43KFCQXQCX634T", .kick),
            ("https://www.tumblr.com/zoesupreme/824038832417767424", .tumblr),
            ("https://imgur.com/gallery/oCsGh", .imgur),
            ("https://discord.com/channels/1/2/3", .discord),
            ("https://example.com/article", .web),
            ("https://i.redd.it/abc.jpg", .web),
            ("https://cdn.discordapp.com/attachments/1/2/file.mp4", .web)
        ]
        for (raw, expected) in cases {
            let url = LinkParser.normalize(raw)!
            XCTAssertEqual(LinkParser.platform(for: url), expected, raw)
        }
    }

    func testNormalizeStripsTrackingAndUpgradesScheme() {
        let url = LinkParser.normalize("youtube.com/watch?v=abc&utm_source=share&si=xyz&feature=shared#t=10")!
        XCTAssertEqual(url.absoluteString, "https://youtube.com/watch?v=abc")
    }

    func testFirstURLInsideSharedText() {
        let url = LinkParser.firstURL(in: "Look at this 😍 https://www.tiktok.com/t/ZTabc/ so good")
        XCTAssertEqual(url?.host, "www.tiktok.com")
        XCTAssertNil(LinkParser.firstURL(in: "just words"))
    }

    func testShortLinksAreRecognised() {
        XCTAssertTrue(LinkParser.isShortLink(URL(string: "https://vm.tiktok.com/ZMabc/")!))
        XCTAssertTrue(LinkParser.isShortLink(URL(string: "https://www.reddit.com/r/aww/s/abc123")!))
        XCTAssertTrue(LinkParser.isShortLink(URL(string: "https://youtu.be/dQw4w9WgXcQ")!))
        XCTAssertFalse(LinkParser.isShortLink(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
    }

    func testIdentifiers() {
        XCTAssertEqual(YouTubeExtractor.videoID(from: URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ")!), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeExtractor.videoID(from: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=3")!), "dQw4w9WgXcQ")
        XCTAssertEqual(TikTokExtractor.itemID(from: URL(string: "https://www.tiktok.com/@a/photo/7300000000000000000")!), "7300000000000000000")
        XCTAssertEqual(InstagramExtractor.shortcode(from: URL(string: "https://www.instagram.com/reel/CyXaQ8Ir4sh/")!), "CyXaQ8Ir4sh")
        XCTAssertEqual(XExtractor.postID(from: URL(string: "https://x.com/jack/status/20/photo/1")!), "20")
        XCTAssertEqual(RedditExtractor.postID(from: URL(string: "https://www.reddit.com/r/aww/comments/2ff9dr/tucked_in/")!), "2ff9dr")
        XCTAssertEqual(BlueskyExtractor.reference(from: URL(string: "https://bsky.app/profile/bsky.app/post/3mmwmla3xph26")!)?.rkey, "3mmwmla3xph26")
        XCTAssertEqual(PinterestExtractor.pinID(from: URL(string: "https://www.pinterest.com/pin/117304765294445383/")!), "117304765294445383")
        XCTAssertEqual(TumblrExtractor.reference(from: URL(string: "https://zoesupreme.tumblr.com/post/824038832417767424/slug")!)?.id, "824038832417767424")
        XCTAssertEqual(ImgurExtractor.reference(from: URL(string: "https://imgur.com/gallery/my-title-AbCdEf")!)?.id, "AbCdEf")
        XCTAssertEqual(ImgurExtractor.reference(from: URL(string: "https://imgur.com/a/oCsGh")!)?.isAlbum, true)
        if case .clip(let id)? = KickExtractor.target(for: URL(string: "https://kick.com/xqc?clip=clip_01H")!) { XCTAssertEqual(id, "clip_01H") } else { XCTFail() }
        XCTAssertEqual(DiscordExtractor.reference(from: URL(string: "https://discord.com/channels/1/2/3")!)?.message, "3")
    }

    /// The embed widget's own token algorithm, checked against values JavaScript produced.
    func testXSyndicationToken() {
        XCTAssertEqual(XExtractor.token(for: "20"), "6dq1a2xwd93")
        XCTAssertEqual(XExtractor.token(for: "1684220301421756416"), "42z4tts4pna")
        XCTAssertEqual(XExtractor.token(for: "1234567890123456789"), "2zqic77uqyk")
        XCTAssertEqual(XExtractor.token(for: "99"), "vl4oc3ref6")
        XCTAssertEqual(XExtractor.token(for: "1950000000000000000"), "4q63syckx6d")
    }

    func testSignedURLExpiry() {
        let url = URL(string: "https://v16m.tiktokcdn.com/x/?a=1&x-expires=1787544000&sig=abc")!
        XCTAssertEqual(SignedURL.expiry(of: url)?.timeIntervalSince1970, 1_787_544_000)
        XCTAssertNil(SignedURL.expiry(of: URL(string: "https://example.com/a.jpg")!))
    }
}
