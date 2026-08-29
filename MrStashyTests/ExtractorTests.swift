import XCTest
@testable import MrStashy

final class ExtractorTests: XCTestCase {
    // MARK: YouTube

    private let innerTube = """
    {"playabilityStatus":{"status":"OK"},
     "videoDetails":{"videoId":"dQw4w9WgXcQ","title":"Never Gonna Give You Up","author":"Rick Astley","channelId":"UC1","lengthSeconds":"213","shortDescription":"The official video.",
       "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg","width":1280,"height":720}]}},
     "streamingData":{
       "formats":[{"itag":18,"url":"https://rr1.googlevideo.com/18","mimeType":"video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"","width":640,"height":360,"bitrate":500000,"qualityLabel":"360p","contentLength":"9000000"}],
       "adaptiveFormats":[
         {"itag":137,"url":"https://rr1.googlevideo.com/137","mimeType":"video/mp4; codecs=\\"avc1.640028\\"","width":1920,"height":1080,"bitrate":4334157,"qualityLabel":"1080p","contentLength":"80000000","fps":25},
         {"itag":401,"url":"https://rr1.googlevideo.com/401","mimeType":"video/mp4; codecs=\\"av01.0.12M.08\\"","width":3840,"height":2160,"bitrate":17400774,"qualityLabel":"2160p","contentLength":"240000000","fps":25},
         {"itag":248,"url":"https://rr1.googlevideo.com/248","mimeType":"video/webm; codecs=\\"vp9\\"","width":1920,"height":1080,"bitrate":1549172,"qualityLabel":"1080p"},
         {"itag":140,"url":"https://rr1.googlevideo.com/140","mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":130000,"contentLength":"3400000"},
         {"itag":251,"url":"https://rr1.googlevideo.com/251","mimeType":"audio/webm; codecs=\\"opus\\"","bitrate":140000}
       ]}}
    """

    func testYouTubeBuildsMuxedLadderWithAACAudio() async throws {
        let registry = ExtractorRegistry.stubbed([StubTransport.json("youtubei/v1/player", innerTube)])
        let post = try await registry.extract("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(post.platform, .youTube)
        XCTAssertEqual(post.author.name, "Rick Astley")
        XCTAssertEqual(post.title, "Never Gonna Give You Up")
        let video = post.items[0]
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.duration, 213)
        // Best first: 4K AV1, then 1080p H.264 muxed, then the 360p single file. VP9/Opus never appear.
        XCTAssertEqual(video.variants.map(\.label), ["2160p", "1080p", "360p (single file)"])
        XCTAssertEqual(video.variants[0].codec, "AV1")
        if case .muxed(let videoURL, let audioURL) = video.variants[1].delivery {
            XCTAssertEqual(videoURL.absoluteString, "https://rr1.googlevideo.com/137")
            XCTAssertEqual(audioURL.absoluteString, "https://rr1.googlevideo.com/140")
        } else {
            XCTFail("1080p should be muxed from separate streams")
        }
        XCTAssertEqual(video.variants[1].sizeBytes, 83_400_000)
        XCTAssertEqual(video.variants[1].headers["User-Agent"]?.hasPrefix("com.google.ios.youtube"), true)
        XCTAssertEqual(post.items[1].kind, .photo)
        XCTAssertEqual(post.notes.count, 1, "AV1 at the top of the ladder is flagged")
    }

    func testYouTubeLoginRequiredIsReported() async {
        let body = "{\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\",\"reason\":\"Sign in to confirm your age\"}}"
        let registry = ExtractorRegistry.stubbed([StubTransport.json("youtubei/v1/player", body)])
        do {
            _ = try await registry.extract("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? StashyError, .loginRequired)
        }
    }

    // MARK: TikTok

    private let playerAPI = """
    {"items":[{"author_info":{"nickname":"Scout","unique_id":"scout2015","avatar_url_list":["https://p16.tiktokcdn.com/a.jpeg"]},"aweme_type":0,"desc":"Scramble up ur name","id_str":"6718335390845095173","create_time":1564234358,
      "video_info":{"cover":{"url_list":["https://p16.tiktokcdn.com/cover.jpeg"]},"meta":{"bitrate":2240963,"duration":10542,"height":1024,"width":576},
        "profiles":[{"bitrate":2240963,"codec_type":"h264","fps":30,"gear_name":"normal_540_0","play_addr":{"data_size":2953029,"height":1024,"width":576,"url_list":["https://v9.tiktokcdn.com/play540"]}},
                    {"bitrate":1200000,"codec_type":"h264","fps":30,"gear_name":"lower_360_0","play_addr":{"data_size":1500000,"height":640,"width":360,"url_list":["https://v9.tiktokcdn.com/play360"]}}],
        "url_list":["https://v9.tiktokcdn.com/play540"]}}],"results":[{"code":"ok"}]}
    """

    func testTikTokFallsBackToPlayerAPIWhenThePageIsWalled() async throws {
        let registry = ExtractorRegistry.stubbed([
            StubTransport.html("/@_/video/", "<html><body>verify you are human</body></html>", status: 200),
            StubTransport.json("player/api/v1/items", playerAPI)
        ])
        let post = try await registry.extract("https://www.tiktok.com/@scout2015/video/6718335390845095173")
        XCTAssertEqual(post.extractor, "tiktok-player.1")
        XCTAssertEqual(post.author.handle, "scout2015")
        XCTAssertEqual(post.items.count, 1)
        let video = post.items[0]
        XCTAssertEqual(video.variants.first?.label, "normal_540_0")
        XCTAssertEqual(video.variants.first?.width, 576)
        XCTAssertEqual(video.variants.first?.headers["Referer"], "https://www.tiktok.com/")
        XCTAssertEqual(video.duration, 10.542)
        XCTAssertEqual(post.canonicalURL.absoluteString, "https://www.tiktok.com/@scout2015/video/6718335390845095173")
    }

    func testTikTokPageStateWinsWhenPresent() async throws {
        let state = """
        {"__DEFAULT_SCOPE__":{"webapp.video-detail":{"statusCode":0,"itemInfo":{"itemStruct":{"id":"1","desc":"hello","createTime":"1564234358",
          "author":{"uniqueId":"scout2015","nickname":"Scout","verified":true,"avatarLarger":"https://p16.tiktokcdn.com/avatar.jpeg"},
          "video":{"width":1080,"height":1920,"duration":10,"cover":"https://p16.tiktokcdn.com/c.jpeg","playAddr":"https://v.tiktokcdn.com/play",
            "bitrateInfo":[{"GearName":"adapt_lowest_1080_1","Bitrate":2000000,"CodecType":"h264","PlayAddr":{"Width":1080,"Height":1920,"DataSize":5000000,"UrlList":["https://v.tiktokcdn.com/1080"]}},
                           {"GearName":"normal_720_0","Bitrate":1000000,"CodecType":"h264","PlayAddr":{"Width":720,"Height":1280,"DataSize":3000000,"UrlList":["https://v.tiktokcdn.com/720"]}}]}}}}}}
        """
        let page = "<html><script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\" type=\"application/json\">\(state)</script></html>"
        let registry = ExtractorRegistry.stubbed([StubTransport.html("/@_/video/", page)])
        let post = try await registry.extract("https://www.tiktok.com/@scout2015/video/6718335390845095173")
        XCTAssertEqual(post.extractor, "tiktok-page.1")
        XCTAssertEqual(post.items[0].variants.map(\.label), ["adapt_lowest_1080_1", "normal_720_0"])
        XCTAssertEqual(post.items[0].variants[0].resolutionLabel, "1080p")
        XCTAssertTrue(post.author.isVerified)
    }

    func testTikTokPhotoPost() async throws {
        let state = """
        {"__DEFAULT_SCOPE__":{"webapp.video-detail":{"statusCode":0,"itemInfo":{"itemStruct":{"id":"1","desc":"slides","createTime":"1564234358","author":{"uniqueId":"a","nickname":"A"},
          "video":{},"imagePost":{"images":[{"imageWidth":1080,"imageHeight":1440,"imageURL":{"urlList":["https://p16.tiktokcdn.com/1.jpeg"]}},{"imageWidth":1080,"imageHeight":1440,"imageURL":{"urlList":["https://p16.tiktokcdn.com/2.jpeg"]}}]}}}}}}
        """
        let page = "<html><script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\" type=\"application/json\">\(state)</script></html>"
        let registry = ExtractorRegistry.stubbed([StubTransport.html("/@_/video/", page)])
        let post = try await registry.extract("https://www.tiktok.com/@a/photo/7300000000000000000")
        XCTAssertEqual(post.items.map(\.kind), [.photo, .photo])
        XCTAssertEqual(post.canonicalURL.path, "/@a/photo/7300000000000000000")
    }

    // MARK: Reddit

    func testRedditVideoIsMuxedFromDASH() async throws {
        let listing = """
        [{"data":{"children":[{"data":{"id":"abc","title":"A clip","selftext":"","author":"someone","permalink":"/r/videos/comments/abc/a_clip/","created_utc":1700000000,"is_video":true,
          "media":{"reddit_video":{"fallback_url":"https://v.redd.it/xyz/DASH_720.mp4?source=fallback","dash_url":"https://v.redd.it/xyz/DASHPlaylist.mpd","has_audio":true,"height":720,"width":1280,"duration":12}},
          "preview":{"images":[{"source":{"url":"https://preview.redd.it/thumb.jpg","width":1280,"height":720}}]}}}]}},{"data":{"children":[]}}]
        """
        let mpd = """
        <MPD><Period><AdaptationSet contentType="video"><Representation id="0" bandwidth="1200000" width="1280" height="720"><BaseURL>DASH_720.mp4</BaseURL></Representation>
        <Representation id="1" bandwidth="2400000" width="1920" height="1080"><BaseURL>DASH_1080.mp4</BaseURL></Representation></AdaptationSet>
        <AdaptationSet contentType="audio"><Representation id="2" bandwidth="128000"><BaseURL>DASH_AUDIO_128.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>
        """
        let registry = ExtractorRegistry.stubbed([
            StubTransport.json("comments/abc.json", listing),
            StubTransport.Route(matches: { $0.url?.absoluteString.contains("DASHPlaylist.mpd") == true }, status: 200, body: Data(mpd.utf8), contentType: "application/dash+xml", finalURL: nil)
        ])
        let post = try await registry.extract("https://www.reddit.com/r/videos/comments/abc/a_clip/")
        XCTAssertEqual(post.title, "A clip")
        XCTAssertEqual(post.author.name, "u/someone")
        let video = post.items[0]
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.variants.map(\.label), ["1080p", "720p"])
        if case .muxed(let v, let a) = video.variants[0].delivery {
            XCTAssertEqual(v.absoluteString, "https://v.redd.it/xyz/DASH_1080.mp4")
            XCTAssertEqual(a.absoluteString, "https://v.redd.it/xyz/DASH_AUDIO_128.mp4")
        } else {
            XCTFail("expected a muxed variant")
        }
    }

    func testRedditGalleryKeepsOrderAndPrefersOriginals() async throws {
        let listing = """
        [{"data":{"children":[{"data":{"id":"g1","title":"Gallery","selftext":"","author":"p","permalink":"/r/pics/comments/g1/gallery/","created_utc":1700000000,"is_gallery":true,
          "gallery_data":{"items":[{"media_id":"bbb","caption":"second"},{"media_id":"aaa"}]},
          "media_metadata":{"aaa":{"status":"valid","m":"image/png","s":{"x":800,"y":600,"u":"https://preview.redd.it/aaa.png?width=800"}},"bbb":{"status":"valid","m":"image/jpg","s":{"x":1000,"y":700,"u":"https://preview.redd.it/bbb.jpg?width=1000"}}}}}]}}]
        """
        let registry = ExtractorRegistry.stubbed([StubTransport.json("comments/g1.json", listing)])
        let post = try await registry.extract("https://www.reddit.com/gallery/g1")
        XCTAssertEqual(post.items.count, 2)
        XCTAssertEqual(post.items[0].best?.delivery.primaryURL.absoluteString, "https://i.redd.it/bbb.jpg")
        XCTAssertEqual(post.items[0].altText, "second")
        XCTAssertEqual(post.items[1].best?.delivery.primaryURL.absoluteString, "https://i.redd.it/aaa.png")
    }

    // MARK: Bluesky

    func testBlueskyPrefersTheOriginalUpload() async throws {
        let thread = """
        {"thread":{"$type":"app.bsky.feed.defs#threadViewPost","post":{"uri":"at://did:plc:abc/app.bsky.feed.post/3k","author":{"did":"did:plc:abc","handle":"bsky.app","displayName":"Bluesky","avatar":"https://cdn.bsky.app/a.jpg"},
          "record":{"text":"We shipped video","createdAt":"2024-09-25T17:00:00.000Z","embed":{"$type":"app.bsky.embed.video","video":{"$type":"blob","ref":{"$link":"bafyvideo"},"mimeType":"video/mp4","size":956983}}},
          "embed":{"$type":"app.bsky.embed.video#view","playlist":"https://video.bsky.app/watch/did/bafyvideo/playlist.m3u8","thumbnail":"https://video.bsky.app/thumb.jpg","aspectRatio":{"width":381,"height":800}}}}}
        """
        let did = "{\"service\":[{\"id\":\"#atproto_pds\",\"type\":\"AtprotoPersonalDataServer\",\"serviceEndpoint\":\"https://pds.example.com\"}]}"
        let registry = ExtractorRegistry.stubbed([
            StubTransport.json("resolveHandle", "{\"did\":\"did:plc:abc\"}"),
            StubTransport.json("getPostThread", thread),
            StubTransport.json("plc.directory/did:plc:abc", did)
        ])
        let post = try await registry.extract("https://bsky.app/profile/bsky.app/post/3k")
        let video = post.items[0]
        XCTAssertEqual(video.variants.count, 2)
        XCTAssertEqual(video.variants[0].label, "original upload")
        XCTAssertEqual(video.variants[0].delivery.primaryURL.absoluteString, "https://pds.example.com/xrpc/com.atproto.sync.getBlob?did=did:plc:abc&cid=bafyvideo")
        if case .hls = video.variants[1].delivery {} else { XCTFail("the CDN stream is the fallback") }
    }

    // MARK: X

    func testXSyndicationVideoAndPhotos() async throws {
        let tweet = """
        {"__typename":"Tweet","id_str":"1","text":"Launch day https://t.co/x","display_text_range":[0,10],"created_at":"2024-01-01T00:00:00.000Z",
         "user":{"name":"SpaceX","screen_name":"SpaceX","profile_image_url_https":"https://pbs.twimg.com/profile_images/1_normal.jpg","is_blue_verified":true},
         "mediaDetails":[{"type":"video","media_url_https":"https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/a.jpg","original_info":{"width":1280,"height":720},
            "video_info":{"duration_millis":30000,"variants":[{"content_type":"application/x-mpegURL","url":"https://video.twimg.com/a.m3u8"},{"bitrate":832000,"content_type":"video/mp4","url":"https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/640x360/a.mp4"},{"bitrate":2176000,"content_type":"video/mp4","url":"https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/b.mp4"}]}},
           {"type":"photo","media_url_https":"https://pbs.twimg.com/media/abc.jpg","original_info":{"width":4000,"height":3000}}]}
        """
        let registry = ExtractorRegistry.stubbed([StubTransport.json("tweet-result", tweet)])
        let post = try await registry.extract("https://x.com/SpaceX/status/1")
        XCTAssertEqual(post.text, "Launch day")
        XCTAssertTrue(post.author.isVerified)
        XCTAssertEqual(post.items[0].variants.first?.delivery.primaryURL.lastPathComponent, "b.mp4")
        XCTAssertEqual(post.items[0].variants.first?.width, 1280)
        XCTAssertEqual(post.items[1].best?.delivery.primaryURL.absoluteString, "https://pbs.twimg.com/media/abc?format=jpg&name=orig")
    }

    // MARK: Instagram / Threads

    func testInstagramGraphQLCarousel() async throws {
        let graphql = """
        {"data":{"xdt_shortcode_media":{"__typename":"XDTGraphSidecar","shortcode":"CyXaQ8Ir4sh","is_video":false,"taken_at_timestamp":1700000000,
          "owner":{"username":"nasa","full_name":"NASA","profile_pic_url":"https://cdn.example/p.jpg","is_verified":true},
          "edge_media_to_caption":{"edges":[{"node":{"text":"Hello space"}}]},
          "edge_sidecar_to_children":{"edges":[
            {"node":{"is_video":true,"video_url":"https://cdn.example/v.mp4","display_url":"https://cdn.example/v.jpg","dimensions":{"width":1080,"height":1350}}},
            {"node":{"is_video":false,"display_url":"https://cdn.example/i.jpg","dimensions":{"width":1080,"height":1350},"display_resources":[{"src":"https://cdn.example/i640.jpg","config_width":640,"config_height":800},{"src":"https://cdn.example/i1080.jpg","config_width":1080,"config_height":1350}]}}]}}}}
        """
        let registry = ExtractorRegistry.stubbed([StubTransport.json("instagram.com/graphql/query", graphql)])
        let post = try await registry.extract("https://www.instagram.com/p/CyXaQ8Ir4sh/")
        XCTAssertEqual(post.author.handle, "nasa")
        XCTAssertEqual(post.text, "Hello space")
        XCTAssertEqual(post.items.map(\.kind), [.video, .photo])
        XCTAssertEqual(post.items[1].best?.delivery.primaryURL.lastPathComponent, "i1080.jpg")
    }

    func testInstagramLoginWallIsHonest() async {
        let registry = ExtractorRegistry.stubbed([
            StubTransport.html("instagram.com/graphql/query", "<html>login</html>", status: 403),
            StubTransport.html("/embed/captioned", "<html><body>Log in to see</body></html>"),
            StubTransport.html("instagram.com/p/", "<html><head><meta property=\"og:image\" content=\"https://static.cdninstagram.com/rsrc.php/static/logo.png\"></head></html>")
        ])
        do {
            _ = try await registry.extract("https://www.instagram.com/p/CyXaQ8Ir4sh/")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StashyError, .loginRequired)
        }
    }

    func testThreadsInlinedThreadItems() async throws {
        let blob = """
        {"data":{"thread_items":[{"post":{"code":"DLJ","pk":"1","taken_at":1700000000,"caption":{"text":"Hi"},"user":{"username":"zuck","full_name":"Mark","profile_pic_url":"https://c/p.jpg","is_verified":true},
          "image_versions2":{"candidates":[{"url":"https://c/1080.jpg","width":1080,"height":1350},{"url":"https://c/640.jpg","width":640,"height":800}]},"original_width":1080,"original_height":1350}}]}}
        """
        let page = "<html><script type=\"application/json\" data-sjs>\(blob)</script></html>"
        let registry = ExtractorRegistry.stubbed([StubTransport.html("threads.com/@zuck/post/DLJ", page)])
        let post = try await registry.extract("https://www.threads.net/@zuck/post/DLJ")
        XCTAssertEqual(post.items.count, 1)
        XCTAssertEqual(post.items[0].best?.width, 1080)
        XCTAssertEqual(post.author.handle, "zuck")
    }

    // MARK: Kick, Snapchat, Imgur, Tumblr, Pinterest, Discord, Web

    func testKickClipIsAStream() async throws {
        let clip = "{\"clip\":{\"id\":\"clip_1\",\"title\":\"big play\",\"duration\":60,\"clip_url\":\"https://clips.kick.com/clips/45/clip_1/playlist.m3u8\",\"thumbnail_url\":\"https://clips.kick.com/t.png\",\"created_at\":\"2024-05-15T18:23:50Z\",\"channel\":{\"username\":\"xqc\",\"slug\":\"xqc\"}}}"
        let registry = ExtractorRegistry.stubbed([StubTransport.json("api/v2/clips/clip_1", clip)])
        let post = try await registry.extract("https://kick.com/xqc/clips/clip_1")
        if case .hls(let url) = post.items[0].best!.delivery { XCTAssertEqual(url.lastPathComponent, "playlist.m3u8") } else { XCTFail() }
        XCTAssertEqual(post.title, "big play")
    }

    func testSnapchatSpotlight() async throws {
        let next = "{\"props\":{\"pageProps\":{\"videoMetadata\":{\"name\":\"New beginnings\",\"contentUrl\":\"https://cf-st.sc-cdn.net/d/abc.mp4\",\"thumbnailUrl\":\"https://bolt.sc-cdn.net/t.jpg\",\"width\":540,\"height\":960,\"durationMs\":\"5840\",\"uploadDateMs\":\"1778625664157\",\"creator\":{\"personCreator\":{\"username\":\"broud\",\"name\":\"Broud\",\"url\":\"https://www.snapchat.com/@broud\"}}}}}}"
        let page = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(next)</script></html>"
        let registry = ExtractorRegistry.stubbed([StubTransport.html("snapchat.com/spotlight", page)])
        let post = try await registry.extract("https://www.snapchat.com/spotlight/W7_abc")
        XCTAssertEqual(post.items[0].kind, .video)
        XCTAssertEqual(post.items[0].duration, 5.84)
        XCTAssertEqual(post.author.handle, "broud")
    }

    func testImgurPost() async throws {
        let body = "{\"id\":\"oCsGh\",\"title\":\"\",\"is_album\":false,\"created_at\":\"2012-04-24T06:51:04Z\",\"media\":[{\"id\":\"oCsGh\",\"url\":\"https://i.imgur.com/oCsGh.jpeg\",\"type\":\"image\",\"width\":640,\"height\":480,\"size\":152036,\"name\":\"DSCI0153\"}]}"
        let registry = ExtractorRegistry.stubbed([StubTransport.json("post/v1/media/oCsGh", body)])
        let post = try await registry.extract("https://imgur.com/gallery/oCsGh")
        XCTAssertEqual(post.items[0].best?.sizeBytes, 152_036)
        XCTAssertEqual(post.canonicalURL.absoluteString, "https://imgur.com/oCsGh")
    }

    func testTumblrBlocks() async throws {
        let state = """
        {"PeeprRoute":{"initialTimeline":{"objects":[{"objectType":"post","blogName":"zoesupreme","blog":{"title":"Zoe"},"timestamp":1700000000,"trail":[],
          "content":[{"type":"text","text":"caption"},{"type":"image","media":[{"type":"image/png","width":1440,"height":1390,"url":"https://64.media.tumblr.com/big.pnj","hasOriginalDimensions":true},{"type":"image/png","width":640,"height":618,"url":"https://64.media.tumblr.com/small.pnj"}]},
                     {"type":"video","media":{"url":"https://va.media.tumblr.com/clip.mp4","width":720,"height":1280},"poster":[{"url":"https://64.media.tumblr.com/poster.jpg"}]}]}]}},"apiFetchStore":{"API_TOKEN":"x"}}
        """
        let page = "<html><script type=\"application/json\" id=\"___INITIAL_STATE___\">\(state)</script></html>"
        let registry = ExtractorRegistry.stubbed([StubTransport.html("tumblr.com/zoesupreme/824", page)])
        let post = try await registry.extract("https://www.tumblr.com/zoesupreme/824038832417767424")
        XCTAssertEqual(post.items.map(\.kind), [.photo, .video])
        XCTAssertEqual(post.items[0].best?.label, "original")
        XCTAssertEqual(post.items[0].best?.container, "png")
        XCTAssertEqual(post.text, "caption")
    }

    func testPinterestVideoPin() async throws {
        let widget = "{\"data\":[{\"id\":\"1\",\"title\":\"Recipe\",\"description\":\"Yum\",\"images\":{\"orig\":{\"url\":\"https://i.pinimg.com/originals/a.jpg\",\"width\":1000,\"height\":1500}},\"videos\":{\"video_list\":{\"V_720P\":{\"url\":\"https://v.pinimg.com/720.mp4\",\"width\":720,\"height\":1280,\"duration\":8000},\"V_HLSV4\":{\"url\":\"https://v.pinimg.com/hls.m3u8\",\"width\":720,\"height\":1280}}},\"pinner\":{\"full_name\":\"Cook\",\"username\":\"cook\"}}]}"
        let registry = ExtractorRegistry.stubbed([StubTransport.json("pidgets/pins/info", widget)])
        let post = try await registry.extract("https://www.pinterest.com/pin/1/")
        XCTAssertEqual(post.items[0].kind, .video)
        XCTAssertEqual(post.items[0].best?.label, "V_720P")
        XCTAssertEqual(post.items[0].duration, 8)
    }

    func testDiscordNeedsBotToken() async {
        let registry = ExtractorRegistry.stubbed([])
        do {
            _ = try await registry.extract("https://discord.com/channels/1/2/3")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StashyError, .loginRequired)
        }
    }

    func testDiscordAttachmentsWithBotToken() async throws {
        let message = "{\"content\":\"look\",\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"author\":{\"id\":\"9\",\"username\":\"amy\",\"global_name\":\"Amy\"},\"attachments\":[{\"url\":\"https://cdn.discordapp.com/attachments/1/2/clip.mp4\",\"filename\":\"clip.mp4\",\"size\":1000,\"content_type\":\"video/mp4\",\"width\":1280,\"height\":720}],\"embeds\":[]}"
        let transport = StubTransport(routes: [StubTransport.json("channels/2/messages/3", message)])
        let registry = ExtractorRegistry(client: HTTPClient(transport: transport), credentials: StaticCredentials(values: [.discordBotToken: "abc.def.ghi"]))
        let post = try await registry.extract("https://discord.com/channels/1/2/3")
        XCTAssertEqual(post.items[0].kind, .video)
        XCTAssertEqual(transport.log.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bot abc.def.ghi")
    }

    func testDirectFileAndGenericPage() async throws {
        let registry = ExtractorRegistry.stubbed([
            StubTransport.media("example.com/clip.mp4", type: "video/mp4", bytes: 256),
            StubTransport.html("example.com/article", "<html><head><meta property=\"og:title\" content=\"Story\"><meta property=\"og:video\" content=\"https://example.com/story.mp4\"><meta property=\"og:image\" content=\"/hero.jpg\"></head><body><video src=\"/inline.mp4\" poster=\"/p.jpg\"></video></body></html>")
        ])
        let file = try await registry.extract("https://example.com/clip.mp4")
        XCTAssertEqual(file.items[0].kind, .video)
        let page = try await registry.extract("https://example.com/article")
        XCTAssertEqual(page.title, "Story")
        XCTAssertEqual(page.items.map(\.kind), [.video, .video, .photo])
        XCTAssertEqual(page.items[2].best?.delivery.primaryURL.absoluteString, "https://example.com/hero.jpg")
    }

    func testShortLinkIsExpandedBeforeExtraction() async throws {
        let registry = ExtractorRegistry.stubbed([
            StubTransport.Route(matches: { $0.url?.host == "vm.tiktok.com" }, status: 200, body: Data(), contentType: "text/html", finalURL: URL(string: "https://www.tiktok.com/@scout2015/video/6718335390845095173?_r=1")!),
            StubTransport.html("/@_/video/", "<html>wall</html>"),
            StubTransport.json("player/api/v1/items", playerAPI)
        ])
        let post = try await registry.extract("https://vm.tiktok.com/ZMabc/")
        XCTAssertEqual(post.platform, .tikTok)
        XCTAssertEqual(post.sourceURL.host, "vm.tiktok.com")
    }
}
