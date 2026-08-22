import AVFoundation
import Foundation
import ImageIO
import UIKit

/// Every archive is a folder: `manifest.json` next to the files it describes. Nothing else
/// is needed to read a post back, which is what makes the `.stash` export a plain copy.
actor ArchiveStore {
    let root: URL
    private let database: LibraryDatabase
    private var organization: Organization

    struct Organization: Codable, Sendable {
        var pinned: Set<UUID> = []
        var collections: [Collection] = []
        var membership: [UUID: [UUID]] = [:]
    }

    init(root: URL? = nil) throws {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Stashy", isDirectory: true)
        self.root = base
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Archives"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Work"), withIntermediateDirectories: true)
        database = try LibraryDatabase(at: base.appendingPathComponent("index.sqlite"))
        if let data = try? Data(contentsOf: base.appendingPathComponent("organization.json")), let saved = try? JSONDecoder.stashy.decode(Organization.self, from: data) {
            organization = saved
        } else {
            organization = Organization()
        }
        // Nothing in the store is ever meant for a backup to the cloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableBase = base
        try? mutableBase.setResourceValues(values)
    }

    var archivesDirectory: URL { root.appendingPathComponent("Archives", isDirectory: true) }
    var workDirectory: URL { root.appendingPathComponent("Work", isDirectory: true) }

    func folder(for id: UUID) -> URL { archivesDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }

    func fileURL(archive: UUID, filename: String) -> URL { folder(for: archive).appendingPathComponent(filename) }

    // MARK: Listing

    func summaries(matching query: String = "") -> [ArchiveSummary] {
        let rows = (try? query.trimmingCharacters(in: .whitespaces).isEmpty ? database.all() : database.search(query)) ?? []
        return rows.map { decorate($0) }
    }

    func summary(for id: UUID) -> ArchiveSummary? {
        summaries().first { $0.id == id }
    }

    func manifest(for id: UUID) throws -> ArchiveManifest {
        let data = try Data(contentsOf: folder(for: id).appendingPathComponent("manifest.json"))
        return try JSONDecoder.stashy.decode(ArchiveManifest.self, from: data)
    }

    func totalBytes() -> Int64 {
        summaries().reduce(0) { $0 + $1.totalBytes }
    }

    /// Rebuilds the index from the folders when it disagrees with the disk (first launch
    /// after an import, a restore, or a cleared index).
    func reconcile() {
        let indexed = Set((try? database.all().map(\.id)) ?? [])
        let folders = (try? FileManager.default.contentsOfDirectory(at: archivesDirectory, includingPropertiesForKeys: nil)) ?? []
        var onDisk = Set<UUID>()
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            onDisk.insert(id)
            if !indexed.contains(id), let manifest = try? manifest(for: id) {
                try? database.upsert(Self.summary(from: manifest, folder: folder))
            }
        }
        for id in indexed.subtracting(onDisk) { try? database.remove(id) }
        // Leftover work folders from an interrupted save are worthless.
        for item in (try? FileManager.default.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: Writing

    func prepareWorkspace(for id: UUID) throws -> URL {
        let workspace = workDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: workspace.path) { try FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    func discardWorkspace(for id: UUID) {
        try? FileManager.default.removeItem(at: workDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Moves verified files into a new archive folder and writes its manifest.
    func commit(manifest: ArchiveManifest, files: [(source: URL, filename: String)]) async throws -> ArchiveSummary {
        let destination = folder(for: manifest.id)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files {
            try FileManager.default.moveItem(at: file.source, to: destination.appendingPathComponent(file.filename))
        }
        var finished = manifest
        try await Self.writeCovers(for: &finished, in: destination)
        let data = try JSONEncoder.stashy.encode(finished)
        try data.write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        let summary = Self.summary(from: finished, folder: destination)
        try database.upsert(summary)
        return decorate(summary)
    }

    /// A still for every video so the library never shows a blank tile.
    private static func writeCovers(for manifest: inout ArchiveManifest, in folder: URL) async throws {
        for index in manifest.files.indices where manifest.files[index].kind == .video {
            let file = folder.appendingPathComponent(manifest.files[index].filename)
            let asset = AVURLAsset(url: file)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1200, height: 1200)
            let duration = (try? await asset.load(.duration)) ?? .zero
            let time = CMTime(seconds: min(1.0, duration.seconds / 2), preferredTimescale: 600)
            if let result = try? await generator.image(at: time), let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.85) {
                let coverName = "cover-\(manifest.files[index].index).jpg"
                try? data.write(to: folder.appendingPathComponent(coverName), options: .atomic)
            }
            // Real dimensions and length, read from the file rather than trusted from the source.
            if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                manifest.files[index].width = Int(abs(rect.width).rounded())
                manifest.files[index].height = Int(abs(rect.height).rounded())
            }
            if duration.seconds.isFinite, duration.seconds > 0 { manifest.files[index].duration = duration.seconds }
        }
        for index in manifest.files.indices where manifest.files[index].kind == .photo || manifest.files[index].kind == .gif {
            let file = folder.appendingPathComponent(manifest.files[index].filename)
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                manifest.files[index].width = properties[kCGImagePropertyPixelWidth] as? Int ?? manifest.files[index].width
                manifest.files[index].height = properties[kCGImagePropertyPixelHeight] as? Int ?? manifest.files[index].height
            }
        }
    }

    static func summary(from manifest: ArchiveManifest, folder: URL) -> ArchiveSummary {
        let cover = manifest.files.first
        var coverFilename = cover?.filename
        if let cover, cover.kind == .video {
            let candidate = "cover-\(cover.index).jpg"
            coverFilename = FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) ? candidate : nil
        } else if let cover, cover.kind == .audio {
            coverFilename = nil
        }
        return ArchiveSummary(
            id: manifest.id, platform: manifest.platform, authorName: manifest.author.display, authorHandle: manifest.author.handle,
            title: manifest.title, text: manifest.text, savedAt: manifest.savedAt, createdAt: manifest.createdAt,
            fileCount: manifest.files.count, videoCount: manifest.files.filter { $0.kind == .video }.count,
            photoCount: manifest.files.filter { $0.kind == .photo || $0.kind == .gif }.count,
            totalBytes: manifest.files.reduce(0) { $0 + $1.sizeBytes },
            coverFilename: coverFilename, coverKind: cover?.kind, folder: folder.lastPathComponent
        )
    }

    func coverURL(for file: ArchivedFile, in archive: UUID) -> URL? {
        let folder = folder(for: archive)
        if file.kind == .video {
            let cover = folder.appendingPathComponent("cover-\(file.index).jpg")
            return FileManager.default.fileExists(atPath: cover.path) ? cover : nil
        }
        if file.kind == .audio { return nil }
        return folder.appendingPathComponent(file.filename)
    }

    // MARK: Deleting

    func delete(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: folder(for: id))
        try database.remove(id)
        organization.pinned.remove(id)
        organization.membership[id] = nil
        persistOrganization()
    }

    func deleteAll() throws {
        for summary in summaries() { try delete(summary.id) }
    }

    // MARK: Organisation

    var collections: [Collection] { organization.collections }

    func isPinned(_ id: UUID) -> Bool { organization.pinned.contains(id) }

    func togglePin(_ id: UUID) {
        if !organization.pinned.insert(id).inserted { organization.pinned.remove(id) }
        persistOrganization()
    }

    func createCollection(named name: String) -> Collection {
        let collection = Collection(name: name)
        organization.collections.append(collection)
        persistOrganization()
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let index = organization.collections.firstIndex(where: { $0.id == id }) else { return }
        organization.collections[index].name = name
        persistOrganization()
    }

    func deleteCollection(_ id: UUID) {
        organization.collections.removeAll { $0.id == id }
        for key in organization.membership.keys { organization.membership[key]?.removeAll { $0 == id } }
        persistOrganization()
    }

    func toggleMembership(archive: UUID, collection: UUID) {
        var list = organization.membership[archive] ?? []
        if let index = list.firstIndex(of: collection) { list.remove(at: index) } else { list.append(collection) }
        organization.membership[archive] = list
        persistOrganization()
    }

    private func decorate(_ summary: ArchiveSummary) -> ArchiveSummary {
        var copy = summary
        copy.isPinned = organization.pinned.contains(summary.id)
        copy.collectionIDs = organization.membership[summary.id] ?? []
        return copy
    }

    private func persistOrganization() {
        if let data = try? JSONEncoder.stashy.encode(organization) {
            try? data.write(to: root.appendingPathComponent("organization.json"), options: .atomic)
        }
    }

    // MARK: Import / export

    func export(_ id: UUID) throws -> URL {
        let summary = summary(for: id)
        let name = Self.exportName(for: summary)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).stash")
        try StashPackage.write(folder: folder(for: id), to: destination)
        return destination
    }

    func importPackage(at url: URL) async throws -> ArchiveSummary {
        let staging = workDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try StashPackage.extract(url, into: staging)
        guard let inner = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) else {
            throw StashyError.verificationFailed
        }
        let data = try Data(contentsOf: inner.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder.stashy.decode(ArchiveManifest.self, from: data)
        for file in manifest.files {
            let path = inner.appendingPathComponent(file.filename)
            guard FileManager.default.fileExists(atPath: path.path), try FileVerifier.sha256(of: path) == file.sha256 else { throw StashyError.verificationFailed }
        }
        let destination = folder(for: manifest.id)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: inner, to: destination)
        let summary = Self.summary(from: manifest, folder: destination)
        try database.upsert(summary)
        return decorate(summary)
    }

    private static func exportName(for summary: ArchiveSummary?) -> String {
        guard let summary else { return "stashy-archive" }
        let raw = "\(summary.platform.rawValue)-\(summary.authorHandle ?? summary.authorName)-\(summary.id.uuidString.prefix(8))"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
