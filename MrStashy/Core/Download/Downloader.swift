import Foundation
import CryptoKit

/// Shared cookie jar: a page that sets a cookie (TikTok's CDN token, for one) needs the same
/// cookie presented when its media is fetched.
enum SharedCookies {
    static let storage: HTTPCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage.shared
}

struct DownloadProgress: Sendable {
    var received: Int64
    var expected: Int64?
}

/// Streams one address to a file. Large files are fetched in ranges because some hosts
/// throttle a single long request, and a range that fails can be retried on its own.
struct Downloader: Sendable {
    static let chunkSize: Int64 = 8 * 1024 * 1024

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = SharedCookies.storage
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    var allowCellular = true

    func download(_ url: URL, headers: [String: String], to destination: URL, progress: @Sendable @escaping (DownloadProgress) -> Void) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else { throw StashyError.storage }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var expected: Int64?
        var attempts = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.allowsCellularAccess = allowCellular
            request.setValue(headers["User-Agent"] ?? UserAgent.desktopSafari, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers where key.lowercased() != "user-agent" { request.setValue(value, forHTTPHeaderField: key) }
            let end = offset + Self.chunkSize - 1
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

            let (bytes, response) = try await Self.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw StashyError.network }
            switch http.statusCode {
            case 200:
                // The host ignored the range: take the whole body in one pass.
                if offset > 0 { throw StashyError.network }
                expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil
                try Self.guardMediaType(http)
                offset += try await Self.stream(bytes, into: handle, offset: offset, expected: expected, progress: progress)
                progress(DownloadProgress(received: offset, expected: expected ?? offset))
                return
            case 206:
                if expected == nil, let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let value = Int64(total) {
                    expected = value
                }
                try Self.guardMediaType(http)
                let chunkLength = http.expectedContentLength
                let written = try await Self.stream(bytes, into: handle, offset: offset, expected: expected, progress: progress)
                offset += written
                if let expected, offset >= expected { progress(DownloadProgress(received: offset, expected: expected)); return }
                if chunkLength > 0, written < chunkLength {
                    // The connection closed early; resume from where it stopped.
                    attempts += 1
                    if attempts > 5 { throw StashyError.network }
                    continue
                }
                if written == 0 { return }
                if written < Self.chunkSize { progress(DownloadProgress(received: offset, expected: expected ?? offset)); return }
            case 416:
                // Asked past the end: the file is complete.
                return
            case 401, 403:
                throw StashyError.expired
            case 404, 410:
                throw StashyError.notFound
            case 429:
                throw StashyError.rateLimited
            default:
                attempts += 1
                if attempts > 3 { throw StashyError.network }
                try await Task.sleep(for: .seconds(Double(attempts)))
            }
        }
    }

    private static func guardMediaType(_ response: HTTPURLResponse) throws {
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.hasPrefix("text/html") || type.contains("application/json") || type.contains("text/plain") {
            throw StashyError.verificationFailed
        }
    }

    private static func stream(_ bytes: URLSession.AsyncBytes, into handle: FileHandle, offset: Int64, expected: Int64?, progress: @Sendable (DownloadProgress) -> Void) async throws -> Int64 {
        var buffer = Data(capacity: 256 * 1024)
        var written: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = now
                    progress(DownloadProgress(received: offset + written, expected: expected))
                }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress(DownloadProgress(received: offset + written, expected: expected))
        return written
    }

    /// Fetches a small resource (a playlist, a segment) into memory.
    func data(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowCellular
        request.setValue(headers["User-Agent"] ?? UserAgent.desktopSafari, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers where key.lowercased() != "user-agent" { request.setValue(value, forHTTPHeaderField: key) }
        var attempts = 0
        while true {
            do {
                let (data, response) = try await Self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw StashyError.network }
                switch http.statusCode {
                case 200 ... 299: return data
                case 401, 403: throw StashyError.expired
                case 404: throw StashyError.notFound
                case 429: throw StashyError.rateLimited
                default: throw StashyError.network
                }
            } catch let error as StashyError where error == .network {
                attempts += 1
                if attempts > 3 { throw error }
                try await Task.sleep(for: .seconds(Double(attempts)))
            }
        }
    }
}

// MARK: - Verification

enum FileVerifier {
    /// Refuses a file that is plainly not what the source promised: an HTML error page saved
    /// as a "video", a zero-byte image, a truncated MP4.
    static func verify(_ file: URL, kind: MediaKind, container: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw StashyError.verificationFailed }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 64) ?? Data()
        guard head.count >= 4 else { throw StashyError.verificationFailed }
        let text = String(decoding: head.prefix(32), as: UTF8.self).lowercased()
        if text.contains("<!doctype") || text.contains("<html") || text.hasPrefix("{\"") || text.hasPrefix("<?xml") {
            throw StashyError.verificationFailed
        }
        let bytes = [UInt8](head)
        switch kind {
        case .photo, .gif:
            let isJPEG = bytes[0] == 0xFF && bytes[1] == 0xD8
            let isPNG = bytes[0] == 0x89 && bytes[1] == 0x50
            let isGIF = bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46
            let isWebP = bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            let isHEIF = head.count >= 12 && String(decoding: head[4 ..< 8], as: UTF8.self) == "ftyp"
            let isBMP = bytes[0] == 0x42 && bytes[1] == 0x4D
            guard isJPEG || isPNG || isGIF || isWebP || isHEIF || isBMP else { throw StashyError.verificationFailed }
        case .video:
            let isMP4 = head.count >= 12 && String(decoding: head[4 ..< 8], as: UTF8.self) == "ftyp"
            let isWebM = bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3
            let isTS = bytes[0] == 0x47
            guard isMP4 || isWebM || isTS else { throw StashyError.verificationFailed }
        case .audio:
            let isMP4 = head.count >= 12 && String(decoding: head[4 ..< 8], as: UTF8.self) == "ftyp"
            let isID3 = bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33
            let isMPEG = bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
            let isOgg = bytes[0] == 0x4F && bytes[1] == 0x67
            let isRIFF = bytes[0] == 0x52 && bytes[1] == 0x49
            let isFLAC = bytes[0] == 0x66 && bytes[1] == 0x4C
            guard isMP4 || isID3 || isMPEG || isOgg || isRIFF || isFLAC else { throw StashyError.verificationFailed }
        }
    }

    /// The real container, read from the bytes, so a `.jpg` address that served PNG is named
    /// truthfully on disk.
    static func actualExtension(of file: URL, fallback: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 16), head.count >= 12 else { return fallback }
        defer { try? handle.close() }
        let bytes = [UInt8](head)
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "jpg" }
        if bytes[0] == 0x89, bytes[1] == 0x50 { return "png" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46, String(decoding: head[8 ..< 12], as: UTF8.self) == "WEBP" { return "webp" }
        if String(decoding: head[4 ..< 8], as: UTF8.self) == "ftyp" {
            let brand = String(decoding: head[8 ..< 12], as: UTF8.self)
            if brand.hasPrefix("hei") || brand.hasPrefix("mif") { return "heic" }
            if brand.hasPrefix("avif") { return "avif" }
            if brand == "M4A " { return "m4a" }
            if brand == "qt  " { return "mov" }
            return fallback == "m4a" ? "m4a" : "mp4"
        }
        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 { return "webm" }
        return fallback
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
