#if DEBUG
import Foundation

/// Launch arguments the UI test run uses so every screen can be photographed without a
/// network: real files are generated on the device and committed as real archives.
enum UITestFixtures {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture") }
    static var resetOnboarding: Bool { ProcessInfo.processInfo.arguments.contains("--reset-onboarding") }
    static var arabic: Bool { ProcessInfo.processInfo.arguments.contains("--arabic") }

    @MainActor
    static func apply(to model: AppModel) async {
        var settings = model.settings
        settings.onboardingDone = !resetOnboarding
        settings.language = arabic ? .arabic : .english
        model.settings = settings
        guard isActive else { return }
        try? await model.store.deleteAll()

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let video = workspace.appendingPathComponent("clip.mp4")
        let hasVideo = await SyntheticMedia.videoMP4(to: video, width: 1280, height: 720, seconds: 4)
        let photo = workspace.appendingPathComponent("photo.png")
        try? SyntheticMedia.photoPNG(width: 1080, height: 1350, seed: 0)?.write(to: photo)
        let second = workspace.appendingPathComponent("photo2.png")
        try? SyntheticMedia.photoPNG(width: 1080, height: 1080, seed: 2)?.write(to: second)
        let gif = workspace.appendingPathComponent("loop.gif")
        try? SyntheticMedia.animatedGIF()?.write(to: gif)

        let fixtures: [(Platform, String, String?, String, [(URL, MediaKind)])] = [
            (.tikTok, "Scout, Suki & Stella", "scout2015", "Scramble up ur name & I'll try to guess it 🐾 #petsoftiktok", hasVideo ? [(video, .video)] : [(photo, .photo)]),
            (.reddit, "u/photographer", "photographer", "Golden hour over the old harbour. Three frames, no edits.", [(photo, .photo), (second, .photo), (gif, .gif)]),
            (.bluesky, "Bluesky", "bsky.app", "We shipped video. Here is what it looks like.", hasVideo ? [(video, .video), (second, .photo)] : [(second, .photo)])
        ]
        for (index, fixture) in fixtures.enumerated() {
            var files: [ArchivedFile] = []
            var staged: [(source: URL, filename: String)] = []
            for (order, media) in fixture.4.enumerated() {
                let copy = workspace.appendingPathComponent("\(index)-\(order).\(media.0.pathExtension)")
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.copyItem(at: media.0, to: copy)
                let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? 0
                let digest = (try? FileVerifier.sha256(of: copy)) ?? ""
                let filename = String(format: "%02d-%@.%@", order + 1, media.1.rawValue, copy.pathExtension)
                files.append(ArchivedFile(id: UUID(), index: order, kind: media.1, filename: filename, sizeBytes: size, sha256: digest, width: nil, height: nil, duration: media.1 == .video ? 4 : nil, codec: media.1 == .video ? "H.264" : "PNG", label: "fixture", altText: nil, sourceURL: URL(string: "https://example.com/\(index)/\(order)")!))
                staged.append((copy, filename))
            }
            let manifest = ArchiveManifest(
                id: UUID(), platform: fixture.0, sourceURL: URL(string: "https://example.com/post/\(index)")!, canonicalURL: URL(string: "https://example.com/post/\(index)")!,
                author: Author(name: fixture.1, handle: fixture.2), title: nil, text: fixture.3, createdAt: Date().addingTimeInterval(Double(-86_400 * (index + 1))), savedAt: Date().addingTimeInterval(Double(-3600 * index)),
                files: files, extractor: "fixture", notes: [], missing: []
            )
            _ = try? await model.store.commit(manifest: manifest, files: staged)
        }
        await model.refreshLibrary()

        // A resolved post, ready to save, so the preview screen can be photographed.
        let items = [
            MediaItem(index: 0, kind: .video, variants: [
                MediaVariant(delivery: .muxed(video: video, audio: video), width: 1920, height: 1080, bitrate: 4_300_000, codec: "H.264", container: "mp4", sizeBytes: 81_000_000, label: "1080p"),
                MediaVariant(delivery: .file(video), width: 1280, height: 720, bitrate: 1_100_000, codec: "H.264", container: "mp4", sizeBytes: 26_000_000, label: "720p")
            ], thumbnailURL: photo, duration: 213),
            MediaItem(index: 1, kind: .photo, variants: [MediaVariant(delivery: .file(photo), width: 1280, height: 720, codec: "JPEG", container: "jpg", sizeBytes: 140_000, label: "cover")], thumbnailURL: second)
        ]
        let post = Post(platform: .youTube, sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, canonicalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, author: Author(name: "Rick Astley", handle: nil), title: "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)", text: "The official video for “Never Gonna Give You Up” by Rick Astley.", createdAt: Date(timeIntervalSince1970: 1_256_428_800), items: items, notes: [], extractor: "fixture")
        model.linkInput = post.sourceURL.absoluteString
        model.catchState = .ready(post)
        model.jobs = [
            SaveJob(request: SaveRequest(post: post, selectedItemIDs: Set(items.map(\.id)), quality: .best, saveToPhotos: false), stage: .downloading, progress: 0.42, bytesReceived: 34_000_000, bytesExpected: 81_140_000, bytesPerSecond: 2_400_000, currentItem: 0),
            SaveJob(request: SaveRequest(post: post, selectedItemIDs: Set(items.map(\.id)), quality: .best, saveToPhotos: false), stage: .done, progress: 1, bytesReceived: 81_140_000, bytesExpected: 81_140_000, savedCount: 2, archiveID: model.library.first?.id)
        ]
    }
}
#endif
