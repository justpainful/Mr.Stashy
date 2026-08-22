import Foundation
import ZIPFoundation

/// A `.stash` file is the archive folder zipped: manifest and media, nothing else. Import
/// refuses paths that escape the destination and anything larger than a phone can hold.
enum StashPackage {
    private static let byteBudget: UInt64 = 8 * 1024 * 1024 * 1024
    private static let entryLimit = 5000

    static func write(folder: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        let archive: Archive
        do { archive = try Archive(url: destination, accessMode: .create) } catch { throw StashyError.storage }
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { throw StashyError.storage }
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
            let relative = file.path.replacingOccurrences(of: folder.path + "/", with: "")
            guard isSafe(relative) else { throw StashyError.storage }
            try archive.addEntry(with: "\(folder.lastPathComponent)/\(relative)", relativeTo: folder.deletingLastPathComponent(), compressionMethod: .none)
        }
    }

    static func extract(_ source: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) } catch { throw StashyError.verificationFailed }
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            guard count <= entryLimit, entry.type == .file || entry.type == .directory, isSafe(entry.path) else { throw StashyError.verificationFailed }
            guard entry.uncompressedSize <= byteBudget else { throw StashyError.storage }
            let target = destination.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(destination.standardizedFileURL.path + "/") else { throw StashyError.verificationFailed }
            if entry.type == .directory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            _ = try archive.extract(entry, bufferSize: 512 * 1024, skipCRC32: false) { chunk in
                total += UInt64(chunk.count)
                if total > byteBudget { throw StashyError.storage }
                try handle.write(contentsOf: chunk)
            }
        }
    }

    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0.isEmpty }
    }
}
