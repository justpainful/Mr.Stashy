import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .catch
    var catchState: CatchState = .idle
    var queueItems: [QueueItem] = []
    var libraryPosts: [ArchivedPostSummary] = []
    var settings = UserSettings.load()
    var onboardingComplete = UserDefaults.standard.bool(forKey: "onboarding.complete")
    var pendingLink: URL?
    var lastError: UserVisibleError?

    private var activeSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var transferSamples: [UUID: QueueTransferSample] = [:]

    let archiveStore = ArchiveStore()
    let resolverRegistry = ResolverRegistry()

    func bootstrap() async {
        await archiveStore.bootstrap()
        libraryPosts = await archiveStore.loadSummaries()
#if DEBUG
        await configureScreenshotFixturesIfNeeded()
#endif
        let links = PendingShareStore.consumePendingURLs()
        if let first = links.first {
            pendingLink = first
            selectedTab = .catch
        }
    }

#if DEBUG
    /// Debug-only local data used by the screenshot UI test. It keeps visual review fully
    /// offline and never enters a Release archive or a user's persisted library.
    private func configureScreenshotFixturesIfNeeded() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing") else { return }
        if arguments.contains("--ui-dark") { settings.appearance = .dark }
        if libraryPosts.isEmpty, let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6mKQAAAAASUVORK5CYII=") {
            _ = try? await archiveStore.saveTextCard(pngData: data, sourcePost: Self.screenshotPost)
            libraryPosts = await archiveStore.loadSummaries()
        }
        if arguments.contains("--ui-results-fixture") { catchState = .ready(Self.screenshotPost) }
    }

    private static let screenshotPost = ResolvedPost(
        id: UUID(uuidString: "7B5D2A34-B9C1-4F53-9F6F-440DDC5B5130")!,
        platform: .directMedia,
        originalURL: URL(string: "https://example.invalid/screenshot-post")!,
        canonicalURL: URL(string: "https://example.invalid/screenshot-post")!,
        author: ResolvedAuthor(platformID: nil, displayName: "Sample archive", username: "sample", avatarURL: nil, profileURL: nil, badges: []),
        text: "A local screenshot fixture with a photo, video, and GIF in original order.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        quotedPost: nil,
        media: [
            screenshotMedia(order: 0, type: .photo, url: "https://example.invalid/one.png"),
            screenshotMedia(order: 1, type: .video, url: "https://example.invalid/two.mp4"),
            screenshotMedia(order: 2, type: .gif, url: "https://example.invalid/three.gif")
        ],
        resolverVersion: "screenshot-fixture.v1",
        warnings: []
    )

    private static func screenshotMedia(order: Int, type: MediaType, url: String) -> ResolvedMedia {
        let variant = MediaVariant(
            id: UUID(), url: URL(string: url)!, headers: [:], expirationDate: nil,
            width: 1920, height: 1080, bitrate: 4_000_000, fps: 30, isHDR: false,
            codec: "h264", container: URL(string: url)!.pathExtension, hasSeparateAudio: false,
            estimatedBytes: 1_024_000, qualityLabel: "Original source", cleanliness: .original
        )
        return ResolvedMedia(id: UUID(), orderIndex: order, type: type, thumbnailURL: nil, variants: [variant], width: 1920, height: 1080, duration: type == .photo ? nil : 12, altText: nil)
    }
#endif

    func resolve(_ rawValue: String) async {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil ? "https://\(trimmed)" : trimmed
        guard let url = URL(string: candidate) else {
            catchState = .failed(.invalidURL)
            return
        }
        catchState = .resolving(.checkingLink)
        do {
            let post = try await resolverRegistry.resolve(url)
            catchState = .ready(post)
        } catch let error as ResolverError {
            catchState = .failed(error)
        } catch {
            catchState = .failed(.networkFailure)
        }
    }

    func enqueueFullPost(_ post: ResolvedPost, selectedIDs: Set<UUID>) {
        enqueue(post: post, selectedIDs: selectedIDs, mode: .fullPost)
    }

    func enqueueMediaOnly(_ post: ResolvedPost, selectedIDs: Set<UUID>) {
        enqueue(post: post, selectedIDs: selectedIDs, mode: .mediaOnly)
    }

    func cancelQueueItem(id: UUID) {
        activeSaveTasks[id]?.cancel()
        activeSaveTasks[id] = nil
        transferSamples[id] = nil
        updateQueueItem(id: id, stage: .cancelled)
    }

    func retryQueueItem(_ item: QueueItem) {
        switch item.stage {
        case .failed, .cancelled:
            enqueue(post: item.post, selectedIDs: item.selectedMediaIDs, mode: item.mode)
        default:
            return
        }
    }

    func isQueueItemActive(_ id: UUID) -> Bool {
        activeSaveTasks[id] != nil
    }

    private func enqueue(post: ResolvedPost, selectedIDs: Set<UUID>, mode: QueueItem.SaveMode) {
        let item = QueueItem(post: post, selectedMediaIDs: selectedIDs, mode: mode)
        queueItems.insert(item, at: 0)
        let task = Task { [weak self] in
            await self?.performSave(item: item, mediaOnly: mode == .mediaOnly)
        }
        activeSaveTasks[item.id] = task
    }

    private func performSave(item: QueueItem, mediaOnly: Bool) async {
        do {
            updateQueueItem(id: item.id, stage: item.selectedMediaIDs.isEmpty ? .creatingArchive : .downloading)
            try await archiveStore.save(post: item.post, selectedMediaIDs: item.selectedMediaIDs, mediaOnly: mediaOnly) { [weak self] progress in
                await self?.apply(progress, toQueueItem: item.id)
            }
            try Task.checkCancellation()

            if settings.saveToPhotos {
                updateQueueItem(id: item.id, stage: .savingToPhotos)
                try await saveArchiveMediaToPhotos(archiveID: item.post.id)
            }
            updateQueueItem(id: item.id, stage: .completed, progress: 1)
            libraryPosts = await archiveStore.loadSummaries()
            if !mediaOnly { selectedTab = .library }
        } catch is CancellationError {
            updateQueueItem(id: item.id, stage: .cancelled)
        } catch {
            updateQueueItem(id: item.id, stage: .failed(error.localizedDescription))
        }
        activeSaveTasks[item.id] = nil
        transferSamples[item.id] = nil
    }

    func completeOnboarding() {
        onboardingComplete = true
        UserDefaults.standard.set(true, forKey: "onboarding.complete")
    }

    private func updateQueueItem(id: UUID, stage: QueueItem.Stage, progress: Double? = nil) {
        guard let index = queueItems.firstIndex(where: { $0.id == id }) else { return }
        queueItems[index].stage = stage
        if let progress { queueItems[index].progress = progress }
    }

    private func apply(_ update: ArchiveSaveProgress, toQueueItem id: UUID) {
        guard let index = queueItems.firstIndex(where: { $0.id == id }) else { return }
        let now = Date.now
        var sample = transferSamples[id] ?? QueueTransferSample()
        if update.mediaIndex > sample.mediaIndex {
            sample.completedPriorMediaBytes += sample.currentMediaBytes
            sample.mediaIndex = update.mediaIndex
            sample.currentMediaBytes = 0
        }
        let overallBytes = sample.completedPriorMediaBytes + update.completedBytes
        let elapsed = now.timeIntervalSince(sample.lastUpdated)
        if elapsed > 0 {
            let transferred = max(0, overallBytes - sample.overallBytes)
            let instantaneous = Double(transferred) / elapsed
            sample.bytesPerSecond = sample.bytesPerSecond == 0 ? instantaneous : (sample.bytesPerSecond * 0.7) + (instantaneous * 0.3)
        }
        sample.currentMediaBytes = update.completedBytes
        sample.overallBytes = overallBytes
        sample.lastUpdated = now
        transferSamples[id] = sample
        queueItems[index].stage = .downloading
        queueItems[index].bytesDownloaded = update.completedBytes
        queueItems[index].totalBytes = update.expectedBytes
        queueItems[index].bytesPerSecond = sample.bytesPerSecond
        if let expected = update.expectedBytes, sample.bytesPerSecond > 0 {
            queueItems[index].estimatedTimeRemaining = max(0, Double(expected - update.completedBytes) / sample.bytesPerSecond)
        } else {
            queueItems[index].estimatedTimeRemaining = nil
        }
        if let expected = update.expectedBytes, expected > 0 {
            let currentFraction = Double(update.completedBytes) / Double(expected)
            queueItems[index].progress = (Double(update.mediaIndex) + currentFraction) / Double(max(update.mediaCount, 1))
        }
    }

    private func saveArchiveMediaToPhotos(archiveID: UUID) async throws {
        let manifest = try await archiveStore.loadManifest(id: archiveID)
        for record in manifest.orderedMedia where record.type != .audio {
            try Task.checkCancellation()
            guard let filename = record.localFilename,
                  let url = await archiveStore.localMediaURL(archiveID: archiveID, filename: filename) else { continue }
            try await PhotoLibrarySaver.save(url: url, type: record.type)
        }
    }
}

private struct QueueTransferSample {
    var mediaIndex = 0
    var currentMediaBytes: Int64 = 0
    var completedPriorMediaBytes: Int64 = 0
    var overallBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var lastUpdated = Date.now
}


enum AppTab: String, CaseIterable, Identifiable {
    case `catch`, library, queue, settings

    var id: String { rawValue }
    var titleKey: String { "tab.\(rawValue)" }
    var systemImage: String {
        switch self {
        case .catch: "link.badge.plus"
        case .library: "books.vertical"
        case .queue: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

enum CatchStage: String, CaseIterable, Codable, Sendable {
    case checkingLink, resolvingPlatform, findingContent, inspectingVariants, verifyingQuality
    var titleKey: String { "catch.stage.\(rawValue)" }
}

enum CatchState: Equatable {
    case idle
    case resolving(CatchStage)
    case ready(ResolvedPost)
    case failed(ResolverError)
}
