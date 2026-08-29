import Foundation

/// Runs one save from start to finish: picks a variant per item, downloads or assembles
/// it, verifies the bytes, and commits the archive. A variant that fails is replaced by the
/// next one; an item that fails entirely is reported as missing rather than faked.
actor SaveEngine {
    private let store: ArchiveStore
    private let registry: ExtractorRegistry

    init(store: ArchiveStore, registry: ExtractorRegistry) {
        self.store = store
        self.registry = registry
    }

    struct Outcome: Sendable {
        var summary: ArchiveSummary
        var missing: [String]
    }

    func run(_ request: SaveRequest, allowCellular: Bool, report: @Sendable @escaping (SaveJob) -> Void) async throws -> Outcome {
        var job = SaveJob(request: request, stage: .preparing)
        report(job)
        let downloader = Downloader(allowCellular: allowCellular)
        let assembler = MediaAssembler(downloader: downloader)
        let workspace = try await store.prepareWorkspace(for: request.id)
        defer { Task { await store.discardWorkspace(for: request.id) } }

        var post = request.post
        let selected = post.items.filter { request.selectedItemIDs.contains($0.id) }.sorted { $0.index < $1.index }
        let expectedTotal = selected.reduce(Int64(0)) { $0 + ($1.best?.sizeBytes ?? 0) }
        job.bytesExpected = expectedTotal > 0 ? expectedTotal : nil
        job.stage = .downloading
        report(job)

        var files: [ArchivedFile] = []
        var staged: [(source: URL, filename: String)] = []
        var missing: [String] = []
        var completedBytes: Int64 = 0
        let speed = SpeedMeter()
        var refreshed = false

        for (position, item) in selected.enumerated() {
            try Task.checkCancellation()
            job.currentItem = position
            var candidates = Self.candidates(for: item, preference: request.quality)
            var saved: ArchivedFile?
            var failures: [StashyError] = []
            var attempt = 0
            while saved == nil, attempt < candidates.count {
                let variant = candidates[attempt]
                attempt += 1
                if let expiry = variant.expiresAt, expiry < .now, !refreshed {
                    // Signed addresses went stale while waiting in the queue: read the post again.
                    if let fresh = try? await registry.extract(post.sourceURL) {
                        post = fresh
                        refreshed = true
                        if let replacement = fresh.items.first(where: { $0.index == item.index }) {
                            candidates = Self.candidates(for: replacement, preference: request.quality)
                            attempt = 0
                            continue
                        }
                    }
                }
                let itemStart = completedBytes
                let progressJob = job
                let onProgress: @Sendable (DownloadProgress) -> Void = { progress in
                    var update = progressJob
                    update.bytesReceived = itemStart + progress.received
                    let itemFraction = progress.expected.map { Double(progress.received) / Double(max($0, 1)) } ?? 0
                    update.progress = (Double(position) + min(1, itemFraction)) / Double(max(1, selected.count))
                    update.bytesPerSecond = speed.sample(total: update.bytesReceived)
                    report(update)
                }
                do {
                    let produced = try await produce(variant, item: item, position: position, workspace: workspace, downloader: downloader, assembler: assembler, progress: onProgress)
                    var working = job
                    working.stage = .verifying
                    report(working)
                    try FileVerifier.verify(produced.file, kind: item.kind, container: variant.container)
                    let size = (try? FileManager.default.attributesOfItem(atPath: produced.file.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let digest = try FileVerifier.sha256(of: produced.file)
                    let ext = FileVerifier.actualExtension(of: produced.file, fallback: variant.container)
                    let filename = String(format: "%02d-%@.%@", position + 1, item.kind.rawValue, ext)
                    saved = ArchivedFile(
                        id: item.id, index: position, kind: item.kind, filename: filename, sizeBytes: size, sha256: digest,
                        width: variant.width, height: variant.height, duration: item.duration, codec: variant.codec,
                        label: variant.label, altText: item.altText, sourceURL: variant.delivery.primaryURL
                    )
                    staged.append((produced.file, filename))
                    completedBytes += size
                    job.bytesReceived = completedBytes
                    job.savedCount += 1
                    job.stage = .downloading
                    job.progress = Double(position + 1) / Double(max(1, selected.count))
                    report(job)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let known = StashyError.from(error)
                    if known == .cancelled { throw CancellationError() }
                    failures.append(known)
                }
            }
            if saved == nil {
                let reason = (failures.last ?? .noMedia).errorDescription ?? ""
                missing.append(L10n.format("save.missingItem", Int64(position + 1), reason))
            }
            if let saved { files.append(saved) }
        }

        guard !files.isEmpty else { throw StashyError.noMedia }
        job.stage = .assembling
        report(job)
        let manifest = ArchiveManifest(
            id: request.id, platform: post.platform, sourceURL: post.sourceURL, canonicalURL: post.canonicalURL,
            author: post.author, title: post.title, text: post.text, createdAt: post.createdAt, savedAt: .now,
            files: files, extractor: post.extractor, notes: post.notes, missing: missing
        )
        let summary = try await store.commit(manifest: manifest, files: staged)
        job.archiveID = summary.id

        if request.saveToPhotos {
            job.stage = .savingToPhotos
            report(job)
            for file in files where file.kind != .audio {
                let url = await store.fileURL(archive: summary.id, filename: file.filename)
                do {
                    try await PhotoLibrarySaver.save(url: url, kind: file.kind)
                } catch {
                    missing.append(L10n.value("save.photosFailed"))
                    break
                }
            }
        }
        job.stage = .done
        job.progress = 1
        report(job)
        return Outcome(summary: summary, missing: missing)
    }

    // MARK: Variant choice

    /// The order in which variants are attempted for this person's preference. Every list
    /// ends with everything else, so a capped preference still saves *something* when the
    /// source only has a larger file.
    static func candidates(for item: MediaItem, preference: QualityPreference) -> [MediaVariant] {
        let playable = item.variants.filter { MediaAssembler.canDecode(codec: $0.codec) }
        let pool = playable.isEmpty ? item.variants : playable
        switch preference {
        case .best:
            return pool
        case .upTo1080p:
            let fits = pool.filter { max($0.width ?? 0, $0.height ?? 0) <= 1920 && $0.codec != "AV1" }
            let rest = pool.filter { variant in !fits.contains { $0.id == variant.id } }
            return fits + rest.reversed()
        case .dataSaver:
            let sized = pool.filter { $0.pixels > 0 }
            let unsized = pool.filter { $0.pixels == 0 }
            return sized.reversed() + unsized.reversed()
        }
    }

    // MARK: Producing a file

    private struct Produced {
        var file: URL
    }

    private func produce(_ variant: MediaVariant, item: MediaItem, position: Int, workspace: URL, downloader: Downloader, assembler: MediaAssembler, progress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> Produced {
        let base = workspace.appendingPathComponent("item-\(position)-\(variant.id.uuidString.prefix(6))")
        switch variant.delivery {
        case .file(let url):
            let destination = base.appendingPathExtension(variant.container)
            try await downloader.download(url, headers: variant.headers, to: destination, progress: progress)
            return Produced(file: destination)

        case .muxed(let videoURL, let audioURL):
            let videoFile = base.appendingPathExtension("video.mp4")
            let audioFile = base.appendingPathExtension("audio.m4a")
            let output = base.appendingPathExtension("mp4")
            let expectedVideo = variant.sizeBytes
            try await downloader.download(videoURL, headers: variant.headers, to: videoFile) { update in
                progress(DownloadProgress(received: update.received, expected: expectedVideo ?? update.expected))
            }
            let videoBytes = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? NSNumber)?.int64Value ?? 0
            try await downloader.download(audioURL, headers: variant.headers, to: audioFile) { update in
                progress(DownloadProgress(received: videoBytes + update.received, expected: expectedVideo ?? (videoBytes + (update.expected ?? 0))))
            }
            try FileVerifier.verify(videoFile, kind: .video, container: "mp4")
            try FileVerifier.verify(audioFile, kind: .audio, container: "m4a")
            do {
                try await MediaAssembler.mux(video: videoFile, audio: audioFile, output: output)
            } catch {
                throw StashyError.assemblyFailed
            }
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
            return Produced(file: output)

        case .hls(let playlist):
            let output = base.appendingPathExtension("mp4")
            let streamWorkspace = base.appendingPathExtension("segments")
            defer { try? FileManager.default.removeItem(at: streamWorkspace) }
            try await assembler.downloadStream(playlist, headers: variant.headers, to: output, workspace: streamWorkspace, progress: progress)
            return Produced(file: output)
        }
    }
}

/// A rolling estimate of bytes per second from cumulative totals.
final class SpeedMeter: @unchecked Sendable {
    private var samples: [(Date, Int64)] = []
    private let lock = NSLock()

    func sample(total: Int64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        samples.append((now, total))
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        guard let first = samples.first, samples.count > 1 else { return 0 }
        let seconds = now.timeIntervalSince(first.0)
        guard seconds > 0.2 else { return 0 }
        return Double(total - first.1) / seconds
    }
}
