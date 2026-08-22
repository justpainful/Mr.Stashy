import XCTest
@testable import MrStashy

final class StorageAndParsingTests: XCTestCase {
    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stashy-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sampleManifest(files: [ArchivedFile]) -> ArchiveManifest {
        ArchiveManifest(id: UUID(), platform: .x, sourceURL: URL(string: "https://x.com/a/status/1")!, canonicalURL: URL(string: "https://x.com/a/status/1")!, author: Author(name: "Ada", handle: "ada"), title: nil, text: "Hello archive", createdAt: nil, savedAt: .now, files: files, extractor: "test", notes: [], missing: [])
    }

    private func jpegFile(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        // A minimal JPEG header is enough for the verifier and the extension sniffer.
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 64))
        bytes.append(contentsOf: [0xFF, 0xD9])
        try Data(bytes).write(to: url)
        return url
    }

    func testCommitIndexSearchExportImportDelete() async throws {
        let root = temporaryRoot()
        let store = try ArchiveStore(root: root)
        let source = try jpegFile(in: root, name: "in.jpg")
        let digest = try FileVerifier.sha256(of: source)
        let file = ArchivedFile(id: UUID(), index: 0, kind: .photo, filename: "01-photo.jpg", sizeBytes: 77, sha256: digest, width: nil, height: nil, duration: nil, codec: "JPEG", label: "orig", altText: nil, sourceURL: URL(string: "https://pbs.twimg.com/a.jpg")!)
        let manifest = sampleManifest(files: [file])
        let summary = try await store.commit(manifest: manifest, files: [(source, "01-photo.jpg")])
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.coverFilename, "01-photo.jpg")
        XCTAssertEqual(await store.summaries().count, 1)
        XCTAssertEqual(await store.summaries(matching: "hello").count, 1)
        XCTAssertEqual(await store.summaries(matching: "ada").count, 1)
        XCTAssertEqual(await store.summaries(matching: "nothing").count, 0)

        let package = try await store.export(manifest.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        try await store.delete(manifest.id)
        XCTAssertEqual(await store.summaries().count, 0)
        let imported = try await store.importPackage(at: package)
        XCTAssertEqual(imported.id, manifest.id)
        XCTAssertEqual(await store.summaries().count, 1)
        let reread = try await store.manifest(for: manifest.id)
        XCTAssertEqual(reread.files.first?.sha256, digest)
    }

    func testImportRefusesTamperedMedia() async throws {
        let root = temporaryRoot()
        let store = try ArchiveStore(root: root)
        let source = try jpegFile(in: root, name: "in.jpg")
        let file = ArchivedFile(id: UUID(), index: 0, kind: .photo, filename: "01-photo.jpg", sizeBytes: 77, sha256: "deadbeef", width: nil, height: nil, duration: nil, codec: "JPEG", label: "orig", altText: nil, sourceURL: URL(string: "https://pbs.twimg.com/a.jpg")!)
        let manifest = sampleManifest(files: [file])
        _ = try await store.commit(manifest: manifest, files: [(source, "01-photo.jpg")])
        let package = try await store.export(manifest.id)
        let other = try ArchiveStore(root: temporaryRoot())
        do {
            _ = try await other.importPackage(at: package)
            XCTFail("a checksum mismatch must be refused")
        } catch {
            XCTAssertEqual(error as? StashyError, .verificationFailed)
        }
    }

    func testPackagePathSafety() {
        XCTAssertTrue(StashPackage.isSafe("abc/manifest.json"))
        XCTAssertFalse(StashPackage.isSafe("../escape.json"))
        XCTAssertFalse(StashPackage.isSafe("/abs/path"))
        XCTAssertFalse(StashPackage.isSafe("a//b"))
    }

    func testOrganisationPersists() async throws {
        let root = temporaryRoot()
        let store = try ArchiveStore(root: root)
        let collection = await store.createCollection(named: "Trips")
        let id = UUID()
        await store.togglePin(id)
        await store.toggleMembership(archive: id, collection: collection.id)
        let reopened = try ArchiveStore(root: root)
        XCTAssertTrue(await reopened.isPinned(id))
        XCTAssertEqual(await reopened.collections.map(\.name), ["Trips"])
    }

    func testFileVerifierRejectsHTMLDisguisedAsMedia() throws {
        let root = temporaryRoot()
        let fake = root.appendingPathComponent("fake.mp4")
        try Data("<!DOCTYPE html><html>".utf8).write(to: fake)
        XCTAssertThrowsError(try FileVerifier.verify(fake, kind: .video, container: "mp4"))
        let jpeg = try jpegFile(in: root, name: "real.png")
        XCTAssertNoThrow(try FileVerifier.verify(jpeg, kind: .photo, container: "png"))
        XCTAssertEqual(FileVerifier.actualExtension(of: jpeg, fallback: "png"), "jpg")
    }

    func testHLSPlaylistParsing() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=550000,CODECS="avc1.64001e",RESOLUTION=360x758
        360p/video.m3u8?session_id=a
        #EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640020",RESOLUTION=720x1516
        720p/video.m3u8?session_id=a
        """
        let base = URL(string: "https://video.bsky.app/watch/did/cid/playlist.m3u8")!
        XCTAssertTrue(HLSPlaylist.isMaster(master))
        let renditions = HLSPlaylist.renditions(in: master, base: base)
        XCTAssertEqual(renditions.first?.height, 1516)
        XCTAssertEqual(renditions.first?.url.absoluteString, "https://video.bsky.app/watch/did/cid/720p/video.m3u8?session_id=a")

        let media = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-MEDIA-SEQUENCE:3
        #EXT-X-BYTERANGE:2113496@6232576
        #EXTINF:2.000,
        665.ts
        #EXT-X-BYTERANGE:2362784
        #EXTINF:2.000,
        665.ts
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102
        #EXTINF:1.5,
        666.ts
        #EXT-X-ENDLIST
        """
        let parsed = HLSPlaylist.media(in: media, base: URL(string: "https://clips.kick.com/clips/45/x/playlist.m3u8")!)
        XCTAssertTrue(parsed.isComplete)
        XCTAssertEqual(parsed.segments.count, 3)
        XCTAssertEqual(parsed.segments[0].byteRange?.offset, 6_232_576)
        XCTAssertEqual(parsed.segments[1].byteRange?.offset, 6_232_576 + 2_113_496, "a range without an offset continues the previous one")
        XCTAssertEqual(parsed.segments[0].sequence, 3)
        XCTAssertEqual(parsed.segments[2].key?.uri.lastPathComponent, "key.bin")
        XCTAssertEqual(parsed.segments[2].key?.iv, Data([0x00, 0x01, 0x02]))
        XCTAssertEqual(parsed.totalDuration, 5.5, accuracy: 0.001)
    }

    func testJSONValueNavigation() throws {
        let json = try JSONValue.parse(#"{"a":{"b":[{"c":"x","n":"12"},{"c":"y","flag":true}]},"d":null}"#)
        XCTAssertEqual(json.path("a", "b", "1", "c").string, "y")
        XCTAssertEqual(json["a"]["b"][0]["n"].int, 12)
        XCTAssertEqual(json["a"]["b"][1]["flag"].bool, true)
        XCTAssertTrue(json["d"].isNull)
        XCTAssertEqual(json.allObjects(containing: "c").count, 2)
        XCTAssertEqual(json.firstObject(containing: "flag")?["c"].string, "y")
    }

    func testBalancedJSONExtraction() {
        let html = #"<script>window.x = {"thread_items":[{"post":{"code":"A","caption":{"text":"a}b"}}}],"other":1};</script>"#
        let found = HTMLText.balancedJSON(after: "\"thread_items\"", in: html)
        XCTAssertEqual(found.count, 1)
        XCTAssertNoThrow(try JSONValue.parse(found[0]))
        XCTAssertEqual(HTMLText.decode("a &amp; b &#39;c&#39; &quot;d&quot;"), "a & b 'c' \"d\"")
        XCTAssertEqual(HTMLText.plain("<p>Hello<br>world</p>&nbsp;<b>!</b>"), "Hello\nworld\n!")
    }

    func testVariantRankingAndPreferences() {
        let small = MediaVariant(delivery: .file(URL(string: "https://a/360")!), width: 640, height: 360, codec: "H.264", container: "mp4", label: "360p")
        let mid = MediaVariant(delivery: .muxed(video: URL(string: "https://a/1080v")!, audio: URL(string: "https://a/a")!), width: 1920, height: 1080, codec: "H.264", container: "mp4", label: "1080p")
        let big = MediaVariant(delivery: .muxed(video: URL(string: "https://a/2160v")!, audio: URL(string: "https://a/a")!), width: 3840, height: 2160, codec: "AV1", container: "mp4", label: "2160p")
        let ranked = ExtractorRegistry.rank([small, big, mid])
        XCTAssertEqual(ranked.map(\.label), ["2160p", "1080p", "360p"])
        let item = MediaItem(index: 0, kind: .video, variants: ranked)
        let capped = SaveEngine.candidates(for: item, preference: .upTo1080p)
        XCTAssertEqual(capped.first?.label, "1080p")
        XCTAssertEqual(capped.last?.label, "2160p", "an oversize file is still the last resort")
        XCTAssertEqual(SaveEngine.candidates(for: item, preference: .dataSaver).first?.label, "360p")
        XCTAssertEqual(MediaVariant(delivery: .file(URL(string: "https://a")!), width: 3840, height: 2160, container: "mp4", label: "").resolutionLabel, "4K")
        XCTAssertEqual(MediaVariant(delivery: .file(URL(string: "https://a")!), width: 1080, height: 1920, container: "mp4", label: "").resolutionLabel, "1080p")
    }

    func testLocalisationFilesAgreeAndPluralsResolve() throws {
        let english = try strings(for: "en")
        let arabic = try strings(for: "ar")
        XCTAssertEqual(Set(english.keys), Set(arabic.keys), "every key exists in both languages: \(Set(english.keys).symmetricDifference(Set(arabic.keys)))")
        for key in ["tab.catch", "error.loginRequired.fix", "source.youTube", "stage.done"] {
            XCTAssertNotNil(english[key])
        }
        L10n.setLanguage(.arabic)
        XCTAssertEqual(L10n.pluralCategory(0), "zero")
        XCTAssertEqual(L10n.pluralCategory(2), "two")
        XCTAssertEqual(L10n.pluralCategory(7), "few")
        XCTAssertEqual(L10n.pluralCategory(15), "many")
        XCTAssertEqual(L10n.pluralCategory(100), "other")
        XCTAssertTrue(L10n.isRightToLeft)
        L10n.setLanguage(.english)
        XCTAssertEqual(L10n.pluralCategory(1), "one")
        XCTAssertFalse(L10n.isRightToLeft)
        XCTAssertEqual(L10n.plural("detail.files", 1), "1 file")
        XCTAssertEqual(L10n.plural("detail.files", 3), "3 files")
    }

    private func strings(for language: String) throws -> [String: String] {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let url = Bundle(path: path)?.url(forResource: "Localizable", withExtension: "strings") else {
            throw StashyError.storage
        }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: String] ?? [:]
    }
}
