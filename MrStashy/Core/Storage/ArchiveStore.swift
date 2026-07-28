import CryptoKit
import Foundation

actor ArchiveStore {
    private let fileManager = FileManager.default
    private let database = LibraryDatabase()
    private let downloadEngine = DownloadEngine()
    /// Two saves of the same post would move two temporary folders onto one destination and
    /// destroy each other's work, so a post can only be written once at a time.
    private var savesInFlight: Set<UUID> = []
    /// Checksum-to-file map, rebuilt only when the library changes. Rebuilding it per file made
    /// every download walk the whole library.
    private var checksumIndex: [String: URL]?

    private var root: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Stashy", isDirectory: true)
    }
    private var postsRoot: URL { root.appendingPathComponent("Posts", isDirectory: true) }
    private var databaseURL: URL { root.appendingPathComponent("Database/library.sqlite", isDirectory: false) }

    func bootstrap() async {
        sweepInterruptedWork()
        do {
            try await database.migrate(at: databaseURL)
            try await rebuildIndexIfNeeded()
        } catch { /* File manifests remain the safe read-only fallback. */ }
    }

    /// Removes staging folders left by a save that was killed mid-transfer. Cleanup is
    /// otherwise `defer`-only, which does not run when the system terminates the app, and the
    /// folders are dot-prefixed so their bytes were invisible to both the storage figure and
    /// Delete Library — permanently consumed and unreclaimable.
    private func sweepInterruptedWork() {
        guard let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(".tmp-") || name.hasPrefix(".import-") else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    func loadSummaries(matching query: String? = nil) async -> [ArchivedPostSummary] {
        if let summaries = try? await database.summaries(matching: query) { return summaries }
        return fileSummaries()
    }

    func loadMediaSummaries(matching query: String? = nil) -> [ArchivedMediaSummary] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let entries = fileSummaries().flatMap { summary -> [ArchivedMediaSummary] in
            guard let manifest = try? loadManifest(id: summary.id) else { return [] }
            return manifest.orderedMedia.map { record in
                let fileSize: Int64? = record.localFilename.flatMap { filename in
                    guard let mediaURL = localMediaURL(archiveID: summary.id, filename: filename) else { return nil }
                    do {
                        return try mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
                    } catch {
                        return nil
                    }
                }
                return ArchivedMediaSummary(
                    archiveID: summary.id,
                    mediaID: record.mediaID,
                    orderIndex: record.orderIndex,
                    type: record.type,
                    platform: summary.platform,
                    author: summary.author,
                    savedAt: summary.savedAt,
                    localFilename: record.localFilename,
                    fileSize: fileSize,
                    isHDR: record.variant?.isHDR
                )
            }
        }
        guard !trimmed.isEmpty else { return entries.sorted { $0.savedAt > $1.savedAt } }
        return entries.filter {
            $0.author.lowercased().contains(trimmed) ||
            $0.platform.rawValue.lowercased().contains(trimmed) ||
            $0.type.rawValue.lowercased().contains(trimmed)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    private func fileSummaries() -> [ArchivedPostSummary] {
        guard let folders = try? fileManager.contentsOfDirectory(at: postsRoot, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            let url = folder.appendingPathComponent("summary.json")
            return try? JSONDecoder.stashy.decode(ArchivedPostSummary.self, from: Data(contentsOf: url))
        }.sorted { $0.savedAt > $1.savedAt }
    }

    func loadManifest(id: UUID) throws -> ArchiveManifest {
        let url = postsRoot.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")
        return try JSONDecoder.stashy.decode(ArchiveManifest.self, from: Data(contentsOf: url))
    }

    /// Saves a post and returns anything the person should know about the result, such as an
    /// item the source stopped serving partway through. A single unreachable item no longer
    /// discards the whole capture: the archive keeps what it did get, and says what it missed.
    @discardableResult
    func save(
        post: ResolvedPost,
        selectedMediaIDs: Set<UUID>,
        mediaOnly: Bool,
        allowCellular: Bool = true,
        quality: UserSettings.Quality = .original,
        onProgress: @escaping @Sendable (ArchiveSaveProgress) async -> Void = { _ in }
    ) async throws -> [String] {
        try Task.checkCancellation()
        // A readable reason, not a "verification failure": the same post is already saving, and
        // letting both run would have them move two staging folders onto one destination.
        guard savesInFlight.insert(post.id).inserted else { throw StashPackageError.duplicateArchive }
        defer { savesInFlight.remove(post.id) }

        try fileManager.createDirectory(at: postsRoot, withIntermediateDirectories: true)
        let finalDirectory = postsRoot.appendingPathComponent(post.id.uuidString, isDirectory: true)
        let temporary = root.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let selectedMedia = post.media.sorted(by: { $0.orderIndex < $1.orderIndex }).filter { selectedMediaIDs.contains($0.id) }
        var records: [ArchivedMediaRecord] = []
        var warnings = post.warnings
        var lastFailure: Error?
        // A total is only offered when every selected item published a size; a partial total
        // would make the remaining-time estimate confidently wrong.
        let estimates = selectedMedia.compactMap { selectedVariant(for: $0, quality: quality)?.estimatedBytes }
        let overallExpected: Int64? = estimates.count == selectedMedia.count ? estimates.reduce(0, +) : nil
        var completedBefore: Int64 = 0

        for (selectedIndex, item) in selectedMedia.enumerated() {
            try Task.checkCancellation()
            guard let variant = selectedVariant(for: item, quality: quality) else {
                lastFailure = ResolverError.qualityUnavailable
                warnings.append(L10n.format("archive.warning.itemSkipped", Int64(item.orderIndex + 1), ResolverError.qualityUnavailable.localizedDescription))
                continue
            }
            // The final name is decided after the transfer, from what the server and the file's
            // own header say it is. Naming it from the address beforehand meant a signed CDN
            // link with no path extension — the normal TikTok case — landed as `.bin`, which
            // neither the player nor Save to Photos can open.
            let staging = temporary.appendingPathComponent("media").appendingPathComponent("\(item.orderIndex)-\(item.id.uuidString).part")
            do {
                let priorBytes = completedBefore
                let outcome = try await downloadAndVerify(variant: variant, type: item.type, destination: staging, allowCellular: allowCellular) { byteProgress in
                    await onProgress(.init(
                        mediaIndex: selectedIndex,
                        mediaCount: selectedMedia.count,
                        completedBytes: byteProgress.completedBytes,
                        expectedBytes: byteProgress.expectedBytes,
                        overallCompletedBytes: priorBytes + byteProgress.completedBytes,
                        overallExpectedBytes: overallExpected
                    ))
                }
                let destinationName = "\(item.orderIndex)-\(item.id.uuidString).\(outcome.fileExtension)"
                let destination = temporary.appendingPathComponent("media").appendingPathComponent(destinationName)
                try fileManager.moveItem(at: staging, to: destination)
                deduplicateFile(at: destination, checksum: outcome.checksum)
                let archivedVariant = variant.safeArchiveCopy
                records.append(ArchivedMediaRecord(mediaID: item.id, orderIndex: item.orderIndex, type: item.type, originalURL: archivedVariant.url, localFilename: destinationName, checksumSHA256: outcome.checksum, variant: archivedVariant))
                let completedBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                completedBefore += completedBytes
                await onProgress(.init(
                    mediaIndex: selectedIndex + 1,
                    mediaCount: selectedMedia.count,
                    completedBytes: completedBytes,
                    expectedBytes: completedBytes,
                    overallCompletedBytes: completedBefore,
                    overallExpectedBytes: overallExpected
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? fileManager.removeItem(at: staging)
                lastFailure = error
                warnings.append(L10n.format("archive.warning.itemSkipped", Int64(item.orderIndex + 1), error.localizedDescription))
            }
        }
        try Task.checkCancellation()

        // Nothing was saved, so there is no archive to keep and the real reason is reported.
        if records.isEmpty, !selectedMedia.isEmpty { throw lastFailure ?? ResolverError.mediaMissing }

        let manifest = ArchiveManifest(archiveID: post.id, platform: post.platform, canonicalURL: post.canonicalURL, sourceURL: post.originalURL, author: post.author, text: mediaOnly ? "" : post.text, timestamp: post.createdAt, quotedPost: mediaOnly ? nil : post.quotedPost, orderedMedia: records, resolverVersion: post.resolverVersion, savedAt: .now)
        let summary = ArchivedPostSummary(id: post.id, platform: post.platform, author: post.author.displayName, text: mediaOnly ? "" : post.text, mediaCount: records.count, savedAt: manifest.savedAt, localFolderName: post.id.uuidString)
        try JSONEncoder.stashy.encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder.stashy.encode(summary).write(to: temporary.appendingPathComponent("summary.json"), options: .atomic)
        if fileManager.fileExists(atPath: finalDirectory.path) { try fileManager.removeItem(at: finalDirectory) }
        try fileManager.moveItem(at: temporary, to: finalDirectory)
        checksumIndex = nil
        // The on-disk manifest is the source of truth. If the recoverable search index is
        // temporarily unavailable, keep a completed archive rather than misreporting failure.
        try? await database.upsert(summary)
        return warnings
    }

    func deleteArchive(id: UUID) async throws {
        let directory = postsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        guard directory.standardizedFileURL.path.hasPrefix(postsRoot.standardizedFileURL.path) else { throw ResolverError.verificationFailure }
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        checksumIndex = nil
        try await database.remove(archiveID: id)
    }

    func deleteAllArchives() async throws {
        for summary in fileSummaries() {
            try await deleteArchive(id: summary.id)
        }
    }

    /// Reports what the library actually occupies on the volume. Deduplicated files are hard
    /// links sharing one inode, so counting each directory entry reported several times the
    /// real usage and made deleting the duplicates appear to free nothing.
    func storageUsageBytes() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        var countedInodes = Set<Int>()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // Hard links share an inode; each one is its own directory entry.
            if let inode = (try? fileManager.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int,
               !countedInodes.insert(inode).inserted {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    func saveTextCard(pngData: Data, sourcePost: ResolvedPost) async throws -> ArchivedPostSummary {
        try Task.checkCancellation()
        guard !pngData.isEmpty else { throw ResolverError.verificationFailure }
        try fileManager.createDirectory(at: postsRoot, withIntermediateDirectories: true)

        let archiveID = UUID()
        let temporary = root.appendingPathComponent(".tmp-text-\(UUID().uuidString)", isDirectory: true)
        let finalDirectory = postsRoot.appendingPathComponent(archiveID.uuidString, isDirectory: true)
        let filename = "0-text-card.png"
        let mediaURL = temporary.appendingPathComponent("media", isDirectory: true).appendingPathComponent(filename)
        try fileManager.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        try pngData.write(to: mediaURL, options: .atomic)
        try MediaIntegrityVerifier.validate(file: mediaURL, type: .photo)
        let record = ArchivedMediaRecord(
            mediaID: UUID(),
            orderIndex: 0,
            type: .photo,
            originalURL: sourcePost.canonicalURL,
            localFilename: filename,
            checksumSHA256: try SHA256.fileDigest(mediaURL),
            variant: nil
        )
        let manifest = ArchiveManifest(
            archiveID: archiveID,
            platform: sourcePost.platform,
            canonicalURL: sourcePost.canonicalURL,
            sourceURL: sourcePost.originalURL,
            author: sourcePost.author,
            text: sourcePost.text,
            timestamp: sourcePost.createdAt,
            quotedPost: nil,
            orderedMedia: [record],
            resolverVersion: "text-card.v1",
            savedAt: .now
        )
        let summary = ArchivedPostSummary(
            id: archiveID,
            platform: sourcePost.platform,
            author: sourcePost.author.displayName,
            text: sourcePost.text,
            mediaCount: 1,
            savedAt: manifest.savedAt,
            localFolderName: archiveID.uuidString
        )
        try JSONEncoder.stashy.encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder.stashy.encode(summary).write(to: temporary.appendingPathComponent("summary.json"), options: .atomic)
        try fileManager.moveItem(at: temporary, to: finalDirectory)
        checksumIndex = nil
        try? await database.upsert(summary)
        return summary
    }

    func exportStash(id: UUID, to destination: URL) throws {
        let directory = postsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { throw StashPackageError.invalidPackage }
        try StashPackage.write(archiveDirectory: directory, to: destination)
    }

    func importStash(from source: URL) async throws -> ArchivedPostSummary {
        let temporaryRoot = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try StashPackage.extract(from: source, into: temporaryRoot)

        let importedFolders = try fileManager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard importedFolders.count == 1 else { throw StashPackageError.invalidPackage }
        let importedDirectory = importedFolders[0]
        let manifestURL = importedDirectory.appendingPathComponent("manifest.json")
        let summaryURL = importedDirectory.appendingPathComponent("summary.json")
        let manifest = try JSONDecoder.stashy.decode(ArchiveManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == ArchiveManifest.currentSchemaVersion else { throw StashPackageError.unsupportedSchema }
        let summary = try JSONDecoder.stashy.decode(ArchivedPostSummary.self, from: Data(contentsOf: summaryURL))
        guard manifest.archiveID == summary.id,
              summary.localFolderName == manifest.archiveID.uuidString,
              summary.platform == manifest.platform,
              summary.author == manifest.author.displayName,
              summary.mediaCount == manifest.orderedMedia.count
        else { throw StashPackageError.invalidPackage }
        for media in manifest.orderedMedia {
            guard let filename = media.localFilename, filename == URL(fileURLWithPath: filename).lastPathComponent else { throw StashPackageError.unsafePath }
            let mediaURL = importedDirectory.appendingPathComponent("media", isDirectory: true).appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: mediaURL.path) else { throw StashPackageError.invalidPackage }
            guard let expected = media.checksumSHA256, !expected.isEmpty else { throw StashPackageError.checksumMismatch }
            guard try SHA256.fileDigest(mediaURL) == expected else { throw StashPackageError.checksumMismatch }
            try MediaIntegrityVerifier.validate(file: mediaURL, type: media.type)
            deduplicateFile(at: mediaURL, checksum: expected)
        }
        // Only the files the manifest accounts for may enter the library. Moving the extracted
        // folder wholesale let a hand-crafted package smuggle in unlisted files, which then sat
        // in the archive unreferenced by anything.
        let declared = Set(["manifest.json", "summary.json"])
        let declaredMedia = Set(manifest.orderedMedia.compactMap(\.localFilename))
        let present = try fileManager.contentsOfDirectory(at: importedDirectory, includingPropertiesForKeys: nil)
        for entry in present {
            let name = entry.lastPathComponent
            if name == "media" {
                let mediaFiles = try fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
                guard mediaFiles.allSatisfy({ declaredMedia.contains($0.lastPathComponent) }) else {
                    throw StashPackageError.invalidPackage
                }
                continue
            }
            guard declared.contains(name) else { throw StashPackageError.invalidPackage }
        }

        try fileManager.createDirectory(at: postsRoot, withIntermediateDirectories: true)
        let finalDirectory = postsRoot.appendingPathComponent(manifest.archiveID.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: finalDirectory.path) else { throw StashPackageError.duplicateArchive }
        try fileManager.moveItem(at: importedDirectory, to: finalDirectory)
        checksumIndex = nil
        try? await database.upsert(summary)
        return summary
    }

    func localMediaURL(archiveID: UUID, filename: String) -> URL? {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        let url = postsRoot.appendingPathComponent(archiveID.uuidString, isDirectory: true).appendingPathComponent("media", isDirectory: true).appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func rebuildIndexIfNeeded() async throws {
        for summary in fileSummaries() { try await database.upsert(summary) }
    }

    func selectedVariant(for media: ResolvedMedia, quality: UserSettings.Quality) -> MediaVariant? {
        switch quality {
        case .original, .askEveryTime:
            return media.highestVariant
        case .dataSaver:
            return media.variants.min { lhs, rhs in
                let lhsBytes = lhs.estimatedBytes ?? Int64.max
                let rhsBytes = rhs.estimatedBytes ?? Int64.max
                if lhsBytes != rhsBytes { return lhsBytes < rhsBytes }
                let lhsPixels = pixelCount(lhs)
                let rhsPixels = pixelCount(rhs)
                return lhsPixels < rhsPixels
            }
        }
    }

    private func pixelCount(_ variant: MediaVariant) -> Int64 {
        guard let width = variant.width, let height = variant.height else { return .max }
        return Int64(width) * Int64(height)
    }

    private func deduplicateFile(at candidate: URL, checksum: String) {
        guard let existing = existingMediaURL(checksum: checksum), existing.standardizedFileURL != candidate.standardizedFileURL else { return }
        let backup = candidate.deletingLastPathComponent().appendingPathComponent(".dedup-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: candidate, to: backup)
            do {
                try fileManager.linkItem(at: existing, to: candidate)
                try fileManager.removeItem(at: backup)
            } catch {
                try? fileManager.moveItem(at: backup, to: candidate)
            }
        } catch {
            return
        }
    }

    private func existingMediaURL(checksum: String) -> URL? {
        if checksumIndex == nil { checksumIndex = buildChecksumIndex() }
        guard let url = checksumIndex?[checksum] else { return nil }
        // The index outlives individual deletions, so a stale entry is verified before use.
        guard fileManager.fileExists(atPath: url.path) else {
            checksumIndex?[checksum] = nil
            return nil
        }
        return url
    }

    private func buildChecksumIndex() -> [String: URL] {
        var index: [String: URL] = [:]
        for summary in fileSummaries() {
            guard let manifest = try? loadManifest(id: summary.id) else { continue }
            for record in manifest.orderedMedia {
                guard let checksum = record.checksumSHA256, index[checksum] == nil,
                      let filename = record.localFilename,
                      let url = localMediaURL(archiveID: summary.id, filename: filename)
                else { continue }
                index[checksum] = url
            }
        }
        return index
    }

    private struct DownloadOutcome {
        var checksum: String
        var fileExtension: String
    }

    private func downloadAndVerify(
        variant: MediaVariant,
        type: MediaType,
        destination: URL,
        allowCellular: Bool,
        onProgress: @escaping @Sendable (DownloadByteProgress) async -> Void
    ) async throws -> DownloadOutcome {
        if let expiry = variant.expirationDate, expiry < .now { throw ResolverError.expiredMediaURL }
        var request = URLRequest(url: variant.url)
        request.timeoutInterval = 60
        for (key, value) in variant.headers { request.setValue(value, forHTTPHeaderField: key) }
        let http = try await downloadEngine.download(request: request, destination: destination, allowCellular: allowCellular, onProgress: onProgress)
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        for rejected in ["text/html", "application/json", "text/plain", "application/xml", "mpegurl"] where contentType.contains(rejected) {
            throw ResolverError.verificationFailure
        }
        try MediaIntegrityVerifier.validate(file: destination, type: type)
        return DownloadOutcome(
            checksum: try SHA256.fileDigest(destination),
            fileExtension: MediaFileExtension.resolve(contentType: contentType, sourceURL: variant.url, type: type)
        )
    }

}

/// Progress for one save. The store reports absolute totals because it is the only place that
/// knows how many bytes the earlier items already contributed; having the UI accumulate them
/// was what made the byte counter double-count at every item boundary and then jump backwards.
struct ArchiveSaveProgress: Sendable {
    var mediaIndex: Int
    var mediaCount: Int
    var completedBytes: Int64
    var expectedBytes: Int64?
    var overallCompletedBytes: Int64
    var overallExpectedBytes: Int64?
}

/// Chooses the on-disk extension for a saved file.
///
/// The extension is what iOS uses to type a local file, so it decides whether the archived
/// media will play and whether Photos will accept it. A signed CDN address usually carries no
/// extension at all, so the server's declared type is the primary source and the media kind is
/// the backstop — never `bin`, which types as nothing and silently breaks both.
enum MediaFileExtension {
    private static let byMIMEType: [String: String] = [
        "video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v", "video/webm": "webm",
        "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
        "image/heic": "heic", "image/heif": "heic", "image/avif": "avif",
        "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/wav": "wav",
        "audio/x-wav": "wav", "audio/aac": "aac", "audio/flac": "flac", "audio/ogg": "ogg"
    ]

    static func resolve(contentType: String, sourceURL: URL, type: MediaType) -> String {
        // `Content-Type` often carries parameters, e.g. `video/mp4; charset=utf-8`.
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if let known = byMIMEType[mime] { return known }
        let pathExtension = sourceURL.pathExtension.lowercased()
        if !pathExtension.isEmpty, pathExtension.count <= 5, pathExtension.allSatisfy(\.isLetter) || pathExtension.allSatisfy(\.isNumber) {
            return pathExtension
        }
        switch type {
        case .video: return "mp4"
        case .photo: return "jpg"
        case .gif: return "gif"
        case .audio: return "m4a"
        }
    }
}

enum MediaIntegrityVerifier {
    static func validate(file: URL, type: MediaType) throws {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else { throw ResolverError.verificationFailure }

        // Validation intentionally reads only a tiny prefix. Media can be multi-gigabyte;
        // loading it just to check a magic number would undermine local-first performance.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 32) ?? Data()
        let normalizedHeader = Data(String(decoding: header, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .utf8)
        if normalizedHeader.starts(with: Data("<html".utf8)) || normalizedHeader.starts(with: Data("<!doctype".utf8)) {
            throw ResolverError.verificationFailure
        }
        let isISOBaseMedia = header.count >= 8 && header[4 ..< 8] == Data("ftyp".utf8)
        let isRIFF = header.starts(with: Data("RIFF".utf8))
        let isMatroska = header.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
        // ISO base media and RIFF are both container families that hold video, images and audio
        // alike, so the brand at bytes 8..<12 is what actually distinguishes them. Accepting the
        // container alone would let a WebP or an audio-only M4A pass as a video.
        let brand = header.count >= 12 ? String(decoding: header[8 ..< 12], as: UTF8.self).lowercased() : ""
        let riffForm = isRIFF ? brand : ""
        let isoBrand = isISOBaseMedia ? brand : ""
        switch type {
        case .photo, .gif:
            let isImageISO = ["heic", "heix", "hevc", "mif1", "msf1", "avif", "avis"].contains(isoBrand)
            guard header.starts(with: [0xFF, 0xD8])
                || header.starts(with: [0x89, 0x50, 0x4E, 0x47])
                || header.starts(with: Data("GIF".utf8))
                || riffForm == "webp"
                || isImageISO
                || header.starts(with: Data("BM".utf8))
            else { throw ResolverError.verificationFailure }
        case .video:
            // MP4/MOV/HEVC share the ISO base media header; WebM and MKV use EBML; a few hosts
            // still serve AVI inside a RIFF container.
            let isVideoISO = isISOBaseMedia && !["m4a ", "m4b ", "m4p "].contains(isoBrand)
                && !["heic", "heix", "mif1", "msf1", "avif", "avis"].contains(isoBrand)
            guard isVideoISO || isMatroska || riffForm == "avi " else { throw ResolverError.verificationFailure }
        case .audio:
            guard header.starts(with: Data("ID3".utf8))
                || isRIFF
                || isISOBaseMedia
                || isMatroska
                || header.starts(with: Data("OggS".utf8))
                || header.starts(with: Data("fLaC".utf8))
                // A bare MPEG audio frame begins with eleven set sync bits.
                || (header.count >= 2 && header[0] == 0xFF && (header[1] & 0xE0) == 0xE0)
            else { throw ResolverError.verificationFailure }
        }
    }
}

private extension SHA256 {
    static func fileDigest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    static var stashy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var stashy: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
