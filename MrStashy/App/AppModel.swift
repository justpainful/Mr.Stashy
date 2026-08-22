import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    // MARK: State

    var settings: Settings {
        didSet {
            settings.save()
            if settings.language != oldValue.language { L10n.setLanguage(settings.language) }
        }
    }

    enum CatchState: Equatable {
        case idle
        case working(String)
        case ready(Post)
        case failed(StashyError)
    }

    var linkInput = ""
    var catchState: CatchState = .idle
    var jobs: [SaveJob] = []
    var library: [ArchiveSummary] = []
    var collections: [Collection] = []
    var librarySearch = "" { didSet { Task { await refreshLibrary() } } }
    var banner: Banner?
    var storageBytes: Int64 = 0
    var selectedTab: Tab = .catchTab

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    enum Tab: Hashable { case catchTab, library, queue, settings }

    // MARK: Services

    let store: ArchiveStore
    let registry: ExtractorRegistry
    private let engine: SaveEngine
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var queueFile: URL
    private var extractionTask: Task<Void, Never>?

    init(storeRoot: URL? = nil, registry: ExtractorRegistry = ExtractorRegistry()) {
        let settings = Settings.load()
        self.settings = settings
        L10n.setLanguage(settings.language)
        // A store that cannot be created leaves nothing to do; surfacing that is the job of
        // the first screen, which reads `banner`.
        let store = (try? ArchiveStore(root: storeRoot)) ?? (try! ArchiveStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("StashyFallback")))
        self.store = store
        self.registry = registry
        engine = SaveEngine(store: store, registry: registry)
        queueFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Stashy/queue.json")
    }

    func bootstrap() async {
        await store.reconcile()
        await refreshLibrary()
        #if DEBUG
        if UITestFixtures.isActive || UITestFixtures.resetOnboarding {
            await UITestFixtures.apply(to: self)
            return
        }
        #endif
        restoreQueue()
        consumeSharedLinks()
    }

    // MARK: Catch

    func consumeSharedLinks() {
        let shared = PendingShareStore.consumePendingURLs()
        guard let first = shared.first else { return }
        selectedTab = .catchTab
        linkInput = first.absoluteString
        resolve()
    }

    func handle(openURL url: URL) {
        if url.scheme == "stashy" {
            consumeSharedLinks()
            return
        }
        if url.pathExtension.lowercased() == "stash" {
            Task { await importPackage(url) }
            return
        }
        selectedTab = .catchTab
        linkInput = url.absoluteString
        resolve()
    }

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString else {
            banner = Banner(text: L10n.value("catch.clipboardEmpty"), isError: true)
            return
        }
        linkInput = text
        resolve()
    }

    func resolve() {
        let raw = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        extractionTask?.cancel()
        catchState = .working(L10n.value("catch.working"))
        let registry = self.registry
        extractionTask = Task { [weak self] in
            do {
                let post = try await registry.extract(raw)
                guard !Task.isCancelled else { return }
                self?.catchState = .ready(post)
            } catch {
                guard !Task.isCancelled else { return }
                self?.catchState = .failed(StashyError.from(error))
            }
        }
    }

    func clearCatch() {
        extractionTask?.cancel()
        catchState = .idle
        linkInput = ""
    }

    // MARK: Queue

    func enqueue(_ post: Post, selected: Set<UUID>, quality: QualityPreference? = nil, toPhotos: Bool? = nil) {
        let request = SaveRequest(post: post, selectedItemIDs: selected, quality: quality ?? settings.quality, saveToPhotos: toPhotos ?? settings.saveToPhotos)
        jobs.insert(SaveJob(request: request), at: 0)
        persistQueue()
        start(request)
        selectedTab = .queue
        catchState = .idle
        linkInput = ""
    }

    private var running: Set<UUID> = []

    /// Starts the request now if a slot is free; otherwise it waits as `.queued` and is
    /// started when another save ends.
    private func start(_ request: SaveRequest) {
        guard running.count < max(1, settings.parallelDownloads) else { return }
        running.insert(request.id)
        let engine = self.engine
        let allowCellular = settings.allowCellular
        let id = request.id
        let task = Task { [weak self] in
            do {
                let outcome = try await engine.run(request, allowCellular: allowCellular) { job in
                    Task { @MainActor [weak self] in self?.update(job) }
                }
                await self?.finish(id: id, outcome: outcome)
            } catch is CancellationError {
                self?.mark(id: id, stage: .cancelled)
            } catch {
                self?.mark(id: id, stage: .failed(StashyError.from(error).errorDescription ?? ""))
            }
        }
        tasks[id] = task
    }

    private func startNextQueued() {
        for job in jobs.reversed() where job.stage == .queued && tasks[job.id] == nil {
            guard running.count < max(1, settings.parallelDownloads) else { return }
            start(job.request)
        }
    }

    private func update(_ job: SaveJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        var merged = job
        if jobs[index].stage.isFinished { return }
        merged.request = jobs[index].request
        jobs[index] = merged
    }

    private func finish(id: UUID, outcome: SaveEngine.Outcome) async {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].stage = .done
            jobs[index].progress = 1
            jobs[index].archiveID = outcome.summary.id
        }
        tasks[id] = nil
        running.remove(id)
        persistQueue()
        startNextQueued()
        await refreshLibrary()
        if outcome.missing.isEmpty {
            banner = Banner(text: L10n.plural("save.done", outcome.summary.fileCount), isError: false)
        } else {
            banner = Banner(text: L10n.format("save.partial", Int64(outcome.summary.fileCount), Int64(outcome.missing.count)), isError: true)
        }
    }

    private func mark(id: UUID, stage: SaveStage) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].stage = stage }
        tasks[id] = nil
        running.remove(id)
        persistQueue()
        startNextQueued()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        mark(id: id, stage: .cancelled)
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        job.stage = .queued
        job.progress = 0
        job.bytesReceived = 0
        job.savedCount = 0
        jobs[index] = job
        start(job.request)
    }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        running.remove(id)
        jobs.removeAll { $0.id == id }
        persistQueue()
        startNextQueued()
    }

    func clearFinished() {
        jobs.removeAll { $0.stage.isFinished }
        persistQueue()
    }

    var activeJobCount: Int { jobs.filter { !$0.stage.isFinished }.count }

    private func persistQueue() {
        let pending = jobs.filter { !$0.stage.isFinished }.map(\.request)
        try? FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.stashy.encode(pending).write(to: queueFile, options: .atomic)
    }

    private func restoreQueue() {
        guard let data = try? Data(contentsOf: queueFile), let pending = try? JSONDecoder.stashy.decode([SaveRequest].self, from: data) else { return }
        for request in pending where !jobs.contains(where: { $0.id == request.id }) {
            jobs.append(SaveJob(request: request))
            start(request)
        }
    }

    // MARK: Library

    func refreshLibrary() async {
        library = await store.summaries(matching: librarySearch)
        collections = await store.collections
        storageBytes = await store.totalBytes()
    }

    func delete(_ id: UUID) async {
        try? await store.delete(id)
        await refreshLibrary()
    }

    func deleteAllArchives() async {
        try? await store.deleteAll()
        await refreshLibrary()
    }

    func togglePin(_ id: UUID) async {
        await store.togglePin(id)
        await refreshLibrary()
    }

    func createCollection(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = await store.createCollection(named: trimmed)
        await refreshLibrary()
    }

    func deleteCollection(_ id: UUID) async {
        await store.deleteCollection(id)
        await refreshLibrary()
    }

    func toggleMembership(archive: UUID, collection: UUID) async {
        await store.toggleMembership(archive: archive, collection: collection)
        await refreshLibrary()
    }

    func exportArchive(_ id: UUID) async -> URL? {
        do { return try await store.export(id) } catch {
            banner = Banner(text: StashyError.from(error).errorDescription ?? "", isError: true)
            return nil
        }
    }

    func importPackage(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let summary = try await store.importPackage(at: url)
            await refreshLibrary()
            banner = Banner(text: L10n.format("library.imported", summary.headline), isError: false)
            selectedTab = .library
        } catch {
            banner = Banner(text: StashyError.from(error).errorDescription ?? "", isError: true)
        }
    }

    func saveToPhotos(archive: UUID) async {
        guard let manifest = try? await store.manifest(for: archive) else { return }
        var failed = false
        for file in manifest.files where file.kind != .audio {
            let url = await store.fileURL(archive: archive, filename: file.filename)
            do { try await PhotoLibrarySaver.save(url: url, kind: file.kind) } catch { failed = true }
        }
        banner = Banner(text: L10n.value(failed ? "save.photosFailed" : "library.savedToPhotos"), isError: failed)
    }
}
