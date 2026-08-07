import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .catch
    var catchState: CatchState = .idle
    var queueItems: [QueueItem] = []
    var libraryPosts: [ArchivedPostSummary] = []
    var libraryOrganization = LibraryOrganization()
    var settings = UserSettings.load()
    var onboardingComplete = UserDefaults.standard.bool(forKey: "onboarding.complete")
    var pendingLinks: [URL] = []
    var pendingLink: URL? {
        get { pendingLinks.first }
        set {
            if let newValue {
                if !pendingLinks.contains(newValue) { pendingLinks.insert(newValue, at: 0) }
            } else if !pendingLinks.isEmpty {
                pendingLinks.removeFirst()
            }
        }
    }
    /// The address in the Catch field. It lives here rather than in the view because switching
    /// the interface language rebuilds the whole tree, and a half-typed link is not something to
    /// throw away over a settings change.
    var catchURLText = ""
    /// The post whose review has already been opened, so returning from it does not immediately
    /// re-open the same one. Held here for the same reason as the field text.
    var reviewedPostID: UUID?
    var lastError: UserVisibleError?
    /// A save can finish with something worth saying that is not a failure, such as an item the
    /// source stopped serving. Those belong in front of the person, not only in the log.
    var lastNotice: UserVisibleError?

    private var activeSaveTasks: [UUID: Task<Void, Never>] = [:]
    /// The one task draining shared links, owned by the app so no view update can cancel it.
    private var linkDrainTask: Task<Void, Never>?
    private var transferSamples: [UUID: QueueTransferSample] = [:]
    /// Identifies the newest resolve request so a slower earlier one cannot overwrite it.
    private var resolveGeneration = 0
    private let pendingQueueStore = PendingQueueStore()
    private let downloadPermits = DownloadPermitPool()
    private let organizationStore = LibraryOrganizationStore()

    let archiveStore = ArchiveStore()
    let resolverRegistry = ResolverRegistry()

    init() {
        // The lookup bundle has to be installed before the first `body` runs. Doing it from a
        // `.task` meant the first render — tab titles, the whole Catch screen — had already
        // resolved against the device language, so a saved Arabic preference did nothing until
        // something unrelated forced a redraw.
        L10n.setLanguage(settings.language)
    }

    /// Changes the interface language. `L10n`'s bundle is not observable, so it is installed
    /// here, in the same turn as the observable mutation that triggers the redraw.
    func setLanguage(_ language: UserSettings.AppLanguage) {
        L10n.setLanguage(language)
        settings.language = language
        settings.save()
    }

    func bootstrap() async {
        await archiveStore.bootstrap()
        libraryPosts = await archiveStore.loadSummaries()
        libraryOrganization = await organizationStore.load()
#if DEBUG
        await configureScreenshotFixturesIfNeeded()
#endif
        consumePendingShares()
        await restorePendingQueue()
    }

    /// The Share extension can write to the App Group while Stashy is suspended. Read its
    /// queue each time the scene becomes active so those links are available immediately.
    func consumePendingShares() {
        appendPendingLinks(PendingShareStore.consumePendingURLs())
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "stashy" else {
            appendPendingLinks([url])
            return
        }
        var incoming = PendingShareStore.consumePendingURLs()
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            incoming.append(contentsOf: components.queryItems?.filter { $0.name == "url" }.compactMap { item in
                item.value.flatMap(URL.init(string:))
            } ?? [])
        }
        appendPendingLinks(incoming)
    }

    /// Takes the next shared link. Catch calls this whenever a link arrives, including while it
    /// is already on screen, so a shared link is never silently dropped.
    func takeNextPendingLink() -> URL? {
        guard !pendingLinks.isEmpty else { return nil }
        return pendingLinks.removeFirst()
    }

    /// Resolves shared links one at a time, here rather than in the view.
    ///
    /// It used to run from `.task(id:)` on the Catch screen, keyed on the pending-link count and
    /// the busy flag. Taking a link and starting to resolve it changes both — so SwiftUI saw a
    /// new identity, cancelled the very task doing the work, and the cancelled `URLSession` call
    /// surfaced as "could not reach the source". Every link shared into Stashy failed that way,
    /// while the same address typed by hand worked. A task the app owns cannot be cancelled by a
    /// view update.
    func drainPendingLinks() {
        guard linkDrainTask == nil else { return }
        linkDrainTask = Task { [weak self] in
            while let link = self?.takeNextPendingLink() {
                self?.catchURLText = link.absoluteString
                await self?.resolve(link.absoluteString)
            }
            self?.linkDrainTask = nil
        }
    }

    func createCollection(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !libraryOrganization.collections.contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else { return }
        libraryOrganization.collections.append(StashCollection(name: trimmed))
        await persistLibraryOrganization()
    }

    func togglePinned(archiveID: UUID) async {
        if libraryOrganization.pinnedArchiveIDs.contains(archiveID) {
            libraryOrganization.pinnedArchiveIDs.remove(archiveID)
        } else {
            libraryOrganization.pinnedArchiveIDs.insert(archiveID)
        }
        await persistLibraryOrganization()
    }

    func toggleMembership(archiveID: UUID, collectionID: UUID) async {
        var members = libraryOrganization.archiveIDsByCollection[collectionID, default: []]
        if members.contains(archiveID) {
            members.remove(archiveID)
        } else {
            members.insert(archiveID)
        }
        libraryOrganization.archiveIDsByCollection[collectionID] = members
        await persistLibraryOrganization()
    }

    func removeArchiveFromOrganization(_ archiveID: UUID) async {
        libraryOrganization.pinnedArchiveIDs.remove(archiveID)
        let collectionIDs = Array(libraryOrganization.archiveIDsByCollection.keys)
        for collectionID in collectionIDs {
            libraryOrganization.archiveIDsByCollection[collectionID]?.remove(archiveID)
        }
        await persistLibraryOrganization()
    }

    private func persistLibraryOrganization() async {
        do {
            try await organizationStore.save(libraryOrganization)
        } catch {
            lastError = UserVisibleError(message: error.localizedDescription)
        }
    }

    private func appendPendingLinks(_ links: [URL]) {
        for link in links where !pendingLinks.contains(link) { pendingLinks.append(link) }
        guard !links.isEmpty else { return }
        selectedTab = .catch
        drainPendingLinks()
    }

#if DEBUG
    /// Debug-only local data used by the screenshot UI test. It keeps visual review fully
    /// offline and never enters a Release archive or a user's persisted library.
    private func configureScreenshotFixturesIfNeeded() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing") else { return }
        if arguments.contains("--ui-dark") { settings.appearance = .dark }
        // Every screenshot launch is isolated. This prevents an English test collection
        // from leaking into the subsequent Arabic capture.
        libraryOrganization = LibraryOrganization()
        try? await organizationStore.save(libraryOrganization)
        try? await archiveStore.deleteAllArchives()
        libraryPosts = []
        let isArabic = arguments.contains("--ui-arabic") || Locale.preferredLanguages.first?.hasPrefix("ar") == true

        // The fixture writes real files. Pointing it at `example.invalid` meant every thumbnail,
        // replica, and player in the captures drew a placeholder glyph, so the screenshots could
        // never show the media interface they exist to review.
        let files = await Self.screenshotMediaFiles()
        let archived = Self.screenshotPost(id: Self.archivedFixtureID, isArabic: isArabic, files: files)
        try? await archiveStore.saveLocalFixture(
            post: archived,
            files: files.map { (type: $0.type, data: $0.data, filename: $0.filename) }
        )
        libraryPosts = await archiveStore.loadSummaries()
        if arguments.contains("--ui-results-fixture") {
            // A different post from the one in the library, so the review capture shows the save
            // actions rather than the already-saved confirmation for the archived fixture.
            catchState = .ready(Self.screenshotPost(id: UUID(), isArabic: isArabic, files: files))
        }
    }

    private static let archivedFixtureID = UUID(uuidString: "7B5D2A34-B9C1-4F53-9F6F-440DDC5B5130")!

    /// One generated file per media kind, written to a scratch directory so the Catch review can
    /// point its variants at real `file://` addresses.
    private struct ScreenshotFile {
        let type: MediaType
        let filename: String
        let data: Data
        let url: URL
        let width: Int
        let height: Int
        let duration: TimeInterval?
    }

    private static func screenshotMediaFiles() async -> [ScreenshotFile] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("StashyFixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var files: [ScreenshotFile] = []

        if let photo = SyntheticMedia.photoPNG(width: 1_080, height: 1_350, seed: 0) {
            let url = scratch.appendingPathComponent("0-photo.png")
            try? photo.write(to: url, options: .atomic)
            files.append(ScreenshotFile(type: .photo, filename: "0-photo.png", data: photo, url: url, width: 1_080, height: 1_350, duration: nil))
        }
        // Deliberately short and small. The fixture is built during launch, and encoding a
        // long clip delayed the library past the first capture, which photographed an empty
        // archive and called it the empty state.
        let videoURL = scratch.appendingPathComponent("1-video.mp4")
        if await SyntheticMedia.videoMP4(to: videoURL, width: 640, height: 360, seconds: 2, fps: 12),
           let data = try? Data(contentsOf: videoURL) {
            files.append(ScreenshotFile(type: .video, filename: "1-video.mp4", data: data, url: videoURL, width: 640, height: 360, duration: 2))
        }
        if let gif = SyntheticMedia.animatedGIF() {
            let url = scratch.appendingPathComponent("2-loop.gif")
            try? gif.write(to: url, options: .atomic)
            files.append(ScreenshotFile(type: .gif, filename: "2-loop.gif", data: gif, url: url, width: 480, height: 480, duration: 1))
        }
        return files
    }

    private static func screenshotPost(id: UUID, isArabic: Bool, files: [ScreenshotFile]) -> ResolvedPost {
        let poster = files.first { $0.type == .photo }?.url
        return ResolvedPost(
            id: id,
            // An X post so the screenshots exercise the platform-faithful replica, not the
            // generic fallback. The living-post capture then shows the x.com-style card.
            platform: .x,
            originalURL: URL(string: "https://x.com/sample/status/1700000000000000000")!,
            canonicalURL: URL(string: "https://x.com/sample/status/1700000000000000000")!,
            author: ResolvedAuthor(platformID: nil, displayName: isArabic ? "أرشيف تجريبي" : "Sample archive", username: isArabic ? "تجربة" : "sample", avatarURL: nil, profileURL: nil, badges: []),
            text: isArabic ? "منشور تجريبي يحفظ صورة وفيديو وصورة متحركة بالترتيب الأصلي." : "A local screenshot fixture with a photo, video, and GIF in original order.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            quotedPost: nil,
            media: files.enumerated().map { index, file in
                screenshotMedia(order: index, file: file, poster: file.type == .video ? poster : nil)
            },
            resolverVersion: "screenshot-fixture.v2",
            warnings: []
        )
    }

    private static func screenshotMedia(order: Int, file: ScreenshotFile, poster: URL?) -> ResolvedMedia {
        let variant = MediaVariant(
            id: UUID(), url: file.url, headers: [:], expirationDate: nil,
            width: file.width, height: file.height,
            bitrate: file.type == .video ? 4_000_000 : nil,
            fps: file.type == .video ? 24 : nil,
            isHDR: false,
            // A codec only belongs on media that has one. Reporting "H264" for a PNG was a
            // fixture inheriting a video's fields, and it read as a real bug in the review card.
            codec: file.type == .video ? "h264" : nil,
            container: file.url.pathExtension, hasSeparateAudio: false,
            estimatedBytes: Int64(file.data.count), qualityLabel: "Original source", cleanliness: .original
        )
        return ResolvedMedia(
            id: UUID(), orderIndex: order, type: file.type, thumbnailURL: poster,
            variants: [variant], width: file.width, height: file.height,
            duration: file.duration, altText: nil
        )
    }
#endif

    /// Clears a finished result so the Catch screen can return to its starting state instead of
    /// showing yesterday's result or error until the app is relaunched.
    func clearCatchResult() {
        resolveGeneration &+= 1
        catchState = .idle
    }

    func resolve(_ rawValue: String) async {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            catchState = .failed(.invalidURL)
            return
        }
        let candidate = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil ? "https://\(trimmed)" : trimmed
        guard let url = URL(string: candidate), url.host != nil else {
            catchState = .failed(.invalidURL)
            return
        }
        resolveGeneration &+= 1
        let generation = resolveGeneration
        catchState = .resolving(.checkingLink)
        do {
            _ = try URLCanonicalizer.canonicalize(url)
            guard generation == resolveGeneration else { return }
            catchState = .resolving(.resolvingPlatform)
            await Task.yield()
            guard generation == resolveGeneration else { return }
            catchState = .resolving(.findingContent)
            let post = try await resolverRegistry.resolve(url)
            // A newer inspection started while this one was in flight; its result is the one
            // the person is waiting for.
            guard generation == resolveGeneration else { return }
            catchState = .resolving(.inspectingVariants)
            guard !post.media.isEmpty || !post.text.isEmpty else { throw ResolverError.mediaMissing }
            catchState = .resolving(.verifyingQuality)
            guard post.media.allSatisfy({ $0.highestVariant != nil }) else { throw ResolverError.qualityUnavailable }
            catchState = .ready(post)
        } catch let error as ResolverError {
            guard generation == resolveGeneration else { return }
            catchState = .failed(error)
        } catch {
            guard generation == resolveGeneration else { return }
            catchState = .failed(.networkFailure)
        }
    }

    func enqueueFullPost(_ post: ResolvedPost, selectedIDs: Set<UUID>, quality: UserSettings.Quality? = nil) {
        enqueue(post: post, selectedIDs: selectedIDs, mode: .fullPost, quality: quality ?? settings.quality)
    }

    func enqueueMediaOnly(_ post: ResolvedPost, selectedIDs: Set<UUID>, quality: UserSettings.Quality? = nil) {
        enqueue(post: post, selectedIDs: selectedIDs, mode: .mediaOnly, quality: quality ?? settings.quality)
    }

    func cancelQueueItem(id: UUID) {
        activeSaveTasks[id]?.cancel()
        transferSamples[id] = nil
        updateQueueItem(id: id, stage: .cancelled)
    }

    func retryQueueItem(_ item: QueueItem) {
        switch item.stage {
        case .failed, .cancelled:
            guard activeSaveTasks[item.id] == nil else { return }
            // A retry starts over, so last attempt's tally must not be shown against it.
            if let index = queueItems.firstIndex(where: { $0.id == item.id }) {
                queueItems[index].savedMediaCount = nil
            }
            updateQueueItem(id: item.id, stage: .waiting, progress: 0)
            startSave(item)
        default:
            return
        }
    }

    func isQueueItemActive(_ id: UUID) -> Bool {
        activeSaveTasks[id] != nil
    }

    /// Removes one finished row. A queue that can only ever grow stops being a queue.
    func removeQueueItem(id: UUID) {
        guard activeSaveTasks[id] == nil else { return }
        queueItems.removeAll { $0.id == id }
        transferSamples[id] = nil
    }

    func clearFinishedQueueItems() {
        let finished = queueItems.filter { $0.stage.isFinished && activeSaveTasks[$0.id] == nil }
        for item in finished { transferSamples[item.id] = nil }
        queueItems.removeAll { item in finished.contains(where: { $0.id == item.id }) }
    }

    var hasFinishedQueueItems: Bool {
        queueItems.contains { $0.stage.isFinished && activeSaveTasks[$0.id] == nil }
    }

    private func enqueue(post: ResolvedPost, selectedIDs: Set<UUID>, mode: QueueItem.SaveMode, quality: UserSettings.Quality) {
        var item = QueueItem(post: post, selectedMediaIDs: selectedIDs, mode: mode, quality: quality, stage: .waiting)
        item.totalBytes = estimatedTotalBytes(post: post, selectedIDs: selectedIDs)
        queueItems.insert(item, at: 0)
        startSave(item)
        // A result that has been sent to the queue is finished business. Leaving it on the Catch
        // screen kept a green "Review & save" card in front of the paste field for the rest of
        // the session, inviting a second save of something already archived.
        if case .ready(let ready) = catchState, ready.id == post.id {
            catchState = .idle
            catchURLText = ""
            reviewedPostID = nil
        }
    }

    private func startSave(_ item: QueueItem) {
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            let request = PendingQueueRequest(
                id: item.id,
                sourceURL: item.post.originalURL,
                selectedOrderIndices: Set(item.post.media.filter { item.selectedMediaIDs.contains($0.id) }.map(\.orderIndex)),
                mode: item.mode,
                quality: item.quality,
                archiveID: item.post.id
            )
            do {
                try await pendingQueueStore.upsert(request)
            } catch {
                updateQueueItem(id: item.id, stage: .failed(error.localizedDescription))
                activeSaveTasks[item.id] = nil
                return
            }
            do {
                try await downloadPermits.acquire(limit: settings.maxParallelDownloads)
            } catch {
                updateQueueItem(id: item.id, stage: .cancelled)
                try? await pendingQueueStore.remove(id: item.id)
                activeSaveTasks[item.id] = nil
                return
            }
            await self.performSave(item: item, mediaOnly: item.mode == .mediaOnly)
            await downloadPermits.release()
        }
        activeSaveTasks[item.id] = task
    }

    private func performSave(item: QueueItem, mediaOnly: Bool) async {
        do {
            updateQueueItem(id: item.id, stage: item.selectedMediaIDs.isEmpty ? .creatingArchive : .downloading)
            let outcome = try await archiveStore.save(
                post: item.post,
                selectedMediaIDs: item.selectedMediaIDs,
                mediaOnly: mediaOnly,
                allowCellular: settings.allowCellular,
                quality: item.quality
            ) { [weak self] progress in
                await self?.apply(progress, toQueueItem: item.id)
            }
            // The archive is durable the moment `save` returns, so the queue entry goes now
            // rather than after the Photos step, which can sit on a permission alert.
            try? await pendingQueueStore.remove(id: item.id)
            // Cancelling from here would throw away a finished capture and tell the person it
            // did not happen, so the remaining steps are not cancellation points.
            if settings.saveToPhotos {
                updateQueueItem(id: item.id, stage: .savingToPhotos)
                do {
                    try await saveArchiveMediaToPhotos(archiveID: item.post.id)
                } catch {
                    lastNotice = UserVisibleError(message: error.localizedDescription)
                }
            }
            // The row keeps the number of items that actually landed. The notice alert is
            // dismissed and forgotten; the row is what someone comes back to.
            if let index = queueItems.firstIndex(where: { $0.id == item.id }) {
                queueItems[index].savedMediaCount = outcome.savedCount
            }
            updateQueueItem(id: item.id, stage: .completed, progress: 1)
            libraryPosts = await archiveStore.loadSummaries()
            if !outcome.warnings.isEmpty {
                lastNotice = UserVisibleError(message: outcome.warnings.joined(separator: "\n"))
            }
        } catch is CancellationError {
            updateQueueItem(id: item.id, stage: .cancelled)
            try? await pendingQueueStore.remove(id: item.id)
        } catch {
            updateQueueItem(id: item.id, stage: .failed(error.localizedDescription))
            // A save that failed must not be retried automatically on every future launch; the
            // row stays in the queue with a Retry action instead.
            try? await pendingQueueStore.remove(id: item.id)
        }
        activeSaveTasks[item.id] = nil
        transferSamples[item.id] = nil
    }

    private func restorePendingQueue() async {
        let requests = await pendingQueueStore.load()
        for request in requests where activeSaveTasks[request.id] == nil {
            // A post that already finished before the app was killed must not be fetched again.
            // The comparison is against the archive identifier, not the queue row's own.
            if let archiveID = request.archiveID, libraryPosts.contains(where: { $0.id == archiveID }) {
                try? await pendingQueueStore.remove(id: request.id)
                continue
            }
            do {
                let post = try await resolverRegistry.resolve(request.sourceURL)
                let selectedIDs = Set(post.media.filter { request.selectedOrderIndices.contains($0.orderIndex) }.map(\.id))
                guard !selectedIDs.isEmpty || post.media.isEmpty else {
                    // The source no longer exposes the items that were queued, so silently
                    // saving whatever it exposes now would archive something else entirely.
                    try? await pendingQueueStore.remove(id: request.id)
                    lastNotice = UserVisibleError(message: L10n.format("queue.restore.changed", request.sourceURL.host ?? request.sourceURL.absoluteString))
                    continue
                }
                var item = QueueItem(id: request.id, post: post, selectedMediaIDs: selectedIDs, mode: request.mode, quality: request.quality ?? .original, stage: .waiting)
                item.totalBytes = estimatedTotalBytes(post: post, selectedIDs: selectedIDs)
                queueItems.append(item)
                startSave(item)
            } catch {
                try? await pendingQueueStore.remove(id: request.id)
                lastNotice = UserVisibleError(message: error.localizedDescription)
            }
        }
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
        // The transfer's final progress is delivered from an unstructured task, so it can land
        // after the row is already finished. Writing `.downloading` over that would strand a
        // completed row at a fraction, and it would never leave the queue again.
        guard !queueItems[index].stage.isFinished else { return }
        let now = Date.now
        var sample = transferSamples[id] ?? QueueTransferSample()
        // The store reports absolute totals, so the rate is a plain difference: no accumulation
        // across item boundaries and therefore no double counting.
        let overallBytes = update.overallCompletedBytes
        let elapsed = now.timeIntervalSince(sample.lastUpdated)
        if elapsed > 0, overallBytes >= sample.overallBytes {
            let transferred = overallBytes - sample.overallBytes
            let instantaneous = Double(transferred) / elapsed
            sample.bytesPerSecond = sample.bytesPerSecond == 0 ? instantaneous : (sample.bytesPerSecond * 0.7) + (instantaneous * 0.3)
        }
        sample.overallBytes = overallBytes
        sample.lastUpdated = now
        transferSamples[id] = sample

        queueItems[index].stage = .downloading
        queueItems[index].bytesDownloaded = overallBytes
        if let expected = update.overallExpectedBytes, expected > 0 {
            queueItems[index].totalBytes = expected
        } else if update.mediaCount == 1, let expected = update.expectedBytes, expected > 0 {
            queueItems[index].totalBytes = expected
        }
        if let expected = queueItems[index].totalBytes, expected > overallBytes, sample.bytesPerSecond > 0 {
            queueItems[index].estimatedTimeRemaining = Double(expected - overallBytes) / sample.bytesPerSecond
        } else {
            queueItems[index].estimatedTimeRemaining = nil
        }
        queueItems[index].bytesPerSecond = sample.bytesPerSecond
        queueItems[index].progress = fraction(for: update)
    }

    /// Uses byte totals when the source published them and falls back to completed-item count,
    /// so the bar advances even when a host omits a content length.
    private func fraction(for update: ArchiveSaveProgress) -> Double {
        let count = max(update.mediaCount, 1)
        if let expected = update.overallExpectedBytes, expected > 0 {
            return min(1, Double(update.overallCompletedBytes) / Double(expected))
        }
        var completedFraction = 0.0
        if let expected = update.expectedBytes, expected > 0 {
            completedFraction = min(1, Double(update.completedBytes) / Double(expected))
        }
        return min(1, (Double(update.mediaIndex) + completedFraction) / Double(count))
    }

    private func saveArchiveMediaToPhotos(archiveID: UUID) async throws {
        let manifest = try await archiveStore.loadManifest(id: archiveID)
        for record in manifest.orderedMedia where record.type != .audio {
            guard let filename = record.localFilename,
                  let url = await archiveStore.localMediaURL(archiveID: archiveID, filename: filename) else { continue }
            try await PhotoLibrarySaver.save(url: url, type: record.type)
        }
    }

    private func estimatedTotalBytes(post: ResolvedPost, selectedIDs: Set<UUID>) -> Int64? {
        let selected = post.media.filter { selectedIDs.contains($0.id) }
        let estimates = selected.compactMap { $0.highestVariant?.estimatedBytes }
        guard !selected.isEmpty, estimates.count == selected.count else { return nil }
        return estimates.reduce(0, +)
    }
}

private struct QueueTransferSample {
    var overallBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var lastUpdated = Date.now
}

private actor DownloadPermitPool {
    private var active = 0
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    func acquire(limit: Int) async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if active < max(1, limit) {
                    active += 1
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    /// A waiter that is resumed inherits the permit the caller is giving up, so `active` stays
    /// equal to the number of transfers actually running.
    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
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
