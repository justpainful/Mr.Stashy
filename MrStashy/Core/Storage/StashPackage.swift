import Foundation
import ZIPFoundation

enum StashPackageError: LocalizedError {
    case invalidPackage
    case unsafePath
    case unsupportedSchema
    case duplicateArchive
    case checksumMismatch

    // Every one of these reaches the person through the error alert, so they are translated
    // like the rest of the interface rather than being the app's only English sentences.
    var errorDescription: String? {
        switch self {
        case .invalidPackage: L10n.value("stash.error.invalidPackage")
        case .unsafePath: L10n.value("stash.error.unsafePath")
        case .unsupportedSchema: L10n.value("stash.error.unsupportedSchema")
        case .duplicateArchive: L10n.value("stash.error.duplicateArchive")
        case .checksumMismatch: L10n.value("stash.error.checksumMismatch")
        }
    }
}

enum StashPackage {
    private static let maximumUncompressedBytes: UInt64 = 5 * 1_024 * 1_024 * 1_024
    private static let maximumEntryCount = 10_000

    static func write(archiveDirectory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        let zip: Archive
        do { zip = try Archive(url: destination, accessMode: .create) }
        catch { throw StashPackageError.invalidPackage }
        guard let enumerator = fileManager.enumerator(at: archiveDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            throw StashPackageError.invalidPackage
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: archiveDirectory.path + "/", with: "")
            guard isSafeRelativePath(relative) else { throw StashPackageError.unsafePath }
            let entryPath = "\(archiveDirectory.lastPathComponent)/\(relative)"
            try zip.addEntry(with: entryPath, relativeTo: archiveDirectory.deletingLastPathComponent(), compressionMethod: .deflate)
        }
    }

    /// `byteBudget` is injectable so the expansion limit can be exercised by a test without
    /// building a multi-gigabyte fixture.
    static func extract(from source: URL, into destination: URL, byteBudget: UInt64 = maximumUncompressedBytes) throws {
        let fileManager = FileManager.default
        let zip: Archive
        do { zip = try Archive(url: source, accessMode: .read) }
        catch { throw StashPackageError.invalidPackage }
        var totalBytes: UInt64 = 0
        var packageRoot: String?
        var paths = Set<String>()
        var entryCount = 0
        for entry in zip {
            entryCount += 1
            guard entryCount <= maximumEntryCount, paths.insert(entry.path).inserted else {
                throw StashPackageError.invalidPackage
            }
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard entry.type == .file || entry.type == .directory,
                  components.count >= 2,
                  isSafeRelativePath(entry.path) else {
                throw StashPackageError.unsafePath
            }
            if let packageRoot, packageRoot != String(components[0]) { throw StashPackageError.invalidPackage }
            packageRoot = String(components[0])
            // The declared size is written by whoever produced the package, so it is a cheap
            // first rejection and never the thing that actually bounds the write.
            guard entry.uncompressedSize <= byteBudget else { throw StashPackageError.invalidPackage }
            let target = destination.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(destination.standardizedFileURL.path + "/") else { throw StashPackageError.unsafePath }
            if entry.type == .directory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                totalBytes = try write(entry, of: zip, to: target, runningTotal: totalBytes, byteBudget: byteBudget)
            }
        }
    }

    /// Streams one entry to disk and stops the moment the bytes actually produced exceed the
    /// budget. Trusting the size the archive declares is what leaves the door open: a package
    /// can claim one byte and expand to gigabytes.
    private static func write(_ entry: Entry, of zip: Archive, to target: URL, runningTotal: UInt64, byteBudget: UInt64) throws -> UInt64 {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: target)
        guard fileManager.createFile(atPath: target.path, contents: nil) else { throw StashPackageError.invalidPackage }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var total = runningTotal
        do {
            // `extract` verifies the entry's CRC as it reads, so a corrupted package fails here
            // too rather than reaching the manifest checks with damaged bytes.
            _ = try zip.extract(entry, consumer: { chunk in
                total += UInt64(chunk.count)
                guard total <= byteBudget else { throw StashPackageError.invalidPackage }
                try handle.write(contentsOf: chunk)
            })
        } catch {
            try? fileManager.removeItem(at: target)
            throw StashPackageError.invalidPackage
        }
        return total
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}
