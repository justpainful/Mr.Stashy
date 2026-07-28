import Foundation
import Testing
@testable import MrStashy

struct StashPackageTests {
    @Test func packageRoundTripKeepsStructuredArchiveLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveID = UUID()
        let archiveDirectory = root.appendingPathComponent(archiveID.uuidString, isDirectory: true)
        let mediaDirectory = archiveDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let image = mediaDirectory.appendingPathComponent("0-card.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)

        let source = try #require(URL(string: "https://example.invalid/post"))
        let author = ResolvedAuthor(platformID: nil, displayName: "Archive author", username: nil, avatarURL: nil, profileURL: nil, badges: [])
        let record = ArchivedMediaRecord(mediaID: UUID(), orderIndex: 0, type: .photo, originalURL: source, localFilename: "0-card.png", checksumSHA256: nil, variant: nil)
        let manifest = ArchiveManifest(archiveID: archiveID, platform: .directMedia, canonicalURL: source, sourceURL: source, author: author, text: "Saved text", timestamp: nil, quotedPost: nil, orderedMedia: [record], resolverVersion: "test", savedAt: .now)
        let summary = ArchivedPostSummary(id: archiveID, platform: .directMedia, author: author.displayName, text: manifest.text, mediaCount: 1, savedAt: manifest.savedAt, localFolderName: archiveID.uuidString)
        try JSONEncoder.stashy.encode(manifest).write(to: archiveDirectory.appendingPathComponent("manifest.json"))
        try JSONEncoder.stashy.encode(summary).write(to: archiveDirectory.appendingPathComponent("summary.json"))

        let package = root.appendingPathComponent("archive.stash")
        let extraction = root.appendingPathComponent("extraction", isDirectory: true)
        try StashPackage.write(archiveDirectory: archiveDirectory, to: package)
        try StashPackage.extract(from: package, into: extraction)

        let restored = extraction.appendingPathComponent(archiveID.uuidString, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("media/0-card.png").path))
    }

    /// Expansion is bounded by the bytes actually produced, not by the size the package claims.
    /// A package can declare one byte and expand to gigabytes, so the declared value can never
    /// be the thing that stops it.
    @Test func extractionStopsOnceItHasProducedMoreThanItsBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveID = UUID()
        let archiveDirectory = root.appendingPathComponent(archiveID.uuidString, isDirectory: true)
        let mediaDirectory = archiveDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        // Highly compressible, so the stored size is far smaller than what it expands to.
        try Data(repeating: 0, count: 512_000).write(to: mediaDirectory.appendingPathComponent("0-big.bin"))

        let package = root.appendingPathComponent("archive.stash")
        let extraction = root.appendingPathComponent("extraction", isDirectory: true)
        try StashPackage.write(archiveDirectory: archiveDirectory, to: package)

        #expect(throws: StashPackageError.self) {
            try StashPackage.extract(from: package, into: extraction, byteBudget: 4_096)
        }
        // Nothing partial is left behind for the manifest checks to trip over.
        #expect(!FileManager.default.fileExists(atPath: extraction.appendingPathComponent("\(archiveID.uuidString)/media/0-big.bin").path))
    }
}
