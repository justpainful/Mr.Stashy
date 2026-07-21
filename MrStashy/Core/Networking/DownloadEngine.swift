import Foundation

struct DownloadByteProgress: Sendable {
    var completedBytes: Int64
    var expectedBytes: Int64?
}

/// Streams a user-requested media file directly to disk. Progress is based on bytes actually
/// received, never an estimated timer, and is throttled before it reaches SwiftUI state.
actor DownloadEngine {
    private let fileManager = FileManager.default

    func download(
        request: URLRequest,
        destination: URL,
        onProgress: @escaping @Sendable (DownloadByteProgress) async -> Void
    ) async throws -> HTTPURLResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw ResolverError.networkFailure
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else { throw ResolverError.networkFailure }
        var completed: Int64 = 0
        let expected = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        var chunk = Data()
        var lastReport = Date.distantPast
        var completedSuccessfully = false
        defer {
            if !completedSuccessfully { try? fileManager.removeItem(at: destination) }
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            completed += 1
            if chunk.count == 65_536 {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            if Date().timeIntervalSince(lastReport) >= 0.15 {
                await onProgress(.init(completedBytes: completed, expectedBytes: expected))
                lastReport = .now
            }
        }
        if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
        await onProgress(.init(completedBytes: completed, expectedBytes: expected))
        completedSuccessfully = true
        return http
    }
}
