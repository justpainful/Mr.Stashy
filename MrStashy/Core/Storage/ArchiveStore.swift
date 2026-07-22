import CryptoKit
import Foundation

actor ArchiveStore {
    private let fileManager = FileManager.default
    private let database = LibraryDatabase()
    private let downloadEngine = DownloadEngine()

    private var root: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Stashy", isDirectory: true)
    }
    private var postsRoot: URL { root.appendingPathComponent("Posts", isDirectory: true) }
    private var databaseURL: URL { root.appendingPathComponent("Database/library.sqlite", isDirectory: false) }

    func bootstrap() async {
        do {
            try await database.migrate(at: databaseURL)
            try await rebuildIndexIfNeeded()
        } catch { /* File manifests remain the safe read-only fallback. */ }
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

    func save(
        post: ResolvedPost,
        selectedMediaIDs: Set<UUID>,
        mediaOnly: Bool,
        allowCellular: Bool = true,
        onProgress: @escaping @Sendable (ArchiveSaveProgress) async -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: postsRoot, withIntermediateDirectories: true)
        let finalDirectory = postsRoot.appendingPathComponent(post.id.uuidString, isDirectory: true)
        let temporary = root.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        let selectedMedia = post.media.sorted(by: { $0.orderIndex < $1.orderIndex }).filter { selectedMediaIDs.contains($0.id) }
        var records: [ArchivedMediaRecord] = []
        for (selectedIndex, item) in selectedMedia.enumerated() {
            try Task.checkCancellation()
            guard let variant = item.highestVariant else { throw ResolverError.qualityUnavailable }
            let destinationName = "\(item.orderIndex)-\(item.id.uuidString).\(variant.url.pathExtension.isEmpty ? "bin" : variant.url.pathExtension)"
            let destination = temporary.appendingPathComponent("media").appendingPathComponent(destinationName)
            let checksum = try await downloadAndVerify(variant: variant, type: item.type, destination: destination, allowCellular: allowCellular) { byteProgress in
                await onProgress(.init(mediaIndex: selectedIndex, mediaCount: selectedMedia.count, completedBytes: byteProgress.completedBytes, expectedBytes: byteProgress.expectedBytes))
            }
            let archivedVariant = variant.safeArchiveCopy
            records.append(ArchivedMediaRecord(mediaID: item.id, orderIndex: item.orderIndex, type: item.type, originalURL: archivedVariant.url, localFilename: destinationName, checksumSHA256: checksum, variant: archivedVariant))
            let completedBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            await onProgress(.init(mediaIndex: selectedIndex + 1, mediaCount: selectedMedia.count, completedBytes: completedBytes, expectedBytes: completedBytes))
        }
        try Task.checkCancellation()
        let manifest = ArchiveManifest(archiveID: post.id, platform: post.platform, canonicalURL: post.canonicalURL, sourceURL: post.originalURL, author: post.author, text: mediaOnly ? "" : post.text, timestamp: post.createdAt, quotedPost: mediaOnly ? nil : post.quotedPost, orderedMedia: records, resolverVersion: post.resolverVersion, savedAt: .now)
        let summary = ArchivedPostSummary(id: post.id, platform: post.platform, author: post.author.displayName, text: mediaOnly ? "" : post.text, mediaCount: records.count, savedAt: manifest.savedAt, localFolderName: post.id.uuidString)
        try JSONEncoder.stashy.encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder.stashy.encode(summary).write(to: temporary.appendingPathComponent("summary.json"), options: .atomic)
        if fileManager.fileExists(atPath: finalDirectory.path) { try fileManager.removeItem(at: finalDirectory) }
        try fileManager.moveItem(at: temporary, to: finalDirectory)
        // The on-disk manifest is the source of truth. If the recoverable search index is
        // temporarily unavailable, keep a completed archive rather than misreporting failure.
        try? await database.upsert(summary)
    }

    func deleteArchive(id: UUID) async throws {
        let directory = postsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        guard directory.standardizedFileURL.path.hasPrefix(postsRoot.standardizedFileURL.path) else { throw ResolverError.verificationFailure }
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        try await database.remove(archiveID: id)
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
        }
        try fileManager.createDirectory(at: postsRoot, withIntermediateDirectories: true)
        let finalDirectory = postsRoot.appendingPathComponent(manifest.archiveID.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: finalDirectory.path) else { throw StashPackageError.duplicateArchive }
        try fileManager.moveItem(at: importedDirectory, to: finalDirectory)
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

    private func downloadAndVerify(
        variant: MediaVariant,
        type: MediaType,
        destination: URL,
        allowCellular: Bool,
        onProgress: @escaping @Sendable (DownloadByteProgress) async -> Void
    ) async throws -> String {
        var request = URLRequest(url: variant.url)
        request.timeoutInterval = 60
        for (key, value) in variant.headers { request.setValue(value, forHTTPHeaderField: key) }
        let http = try await downloadEngine.download(request: request, destination: destination, allowCellular: allowCellular, onProgress: onProgress)
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard !contentType.contains("text/html"), !contentType.contains("application/json") else { throw ResolverError.verificationFailure }
        try MediaIntegrityVerifier.validate(file: destination, type: type)
        return try SHA256.fileDigest(destination)
    }

}

struct ArchiveSaveProgress: Sendable {
    var mediaIndex: Int
    var mediaCount: Int
    var completedBytes: Int64
    var expectedBytes: Int64?
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
        switch type {
        case .photo, .gif:
            guard header.starts(with: [0xFF, 0xD8]) || header.starts(with: [0x89, 0x50, 0x4E, 0x47]) || header.starts(with: Data("GIF".utf8)) || header.starts(with: Data("RIFF".utf8)) || (header.count >= 8 && header[4...7] == Data("ftyp".utf8)) else { throw ResolverError.verificationFailure }
        case .video:
            guard header.count >= 8, header[4...7] == Data("ftyp".utf8) else { throw ResolverError.verificationFailure }
        case .audio:
            guard header.starts(with: Data("ID3".utf8)) || header.starts(with: Data("RIFF".utf8)) || (header.count >= 8 && header[4...7] == Data("ftyp".utf8)) else { throw ResolverError.verificationFailure }
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
