import Foundation
import ZIPFoundation

enum StashPackageError: LocalizedError {
    case invalidPackage
    case unsafePath
    case unsupportedSchema
    case duplicateArchive
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "The .stash package is invalid or corrupted."
        case .unsafePath: "The .stash package contains an unsafe path."
        case .unsupportedSchema: "This .stash package uses an unsupported schema."
        case .duplicateArchive: "This post is already in the Stashy library."
        case .checksumMismatch: "A media file in the .stash package failed checksum validation."
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

    static func extract(from source: URL, into destination: URL) throws {
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
            totalBytes += entry.uncompressedSize
            guard totalBytes <= maximumUncompressedBytes else { throw StashPackageError.invalidPackage }
            let target = destination.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(destination.standardizedFileURL.path + "/") else { throw StashPackageError.unsafePath }
            if entry.type == .directory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try zip.extract(entry, to: target)
            }
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}
