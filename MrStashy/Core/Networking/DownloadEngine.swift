import Foundation

struct DownloadByteProgress: Sendable {
    var completedBytes: Int64
    var expectedBytes: Int64?
}

/// Streams a user-requested media file to disk with `URLSession`'s own file-backed transfer.
/// Progress comes from bytes actually written by the loader, never from an estimated timer, and
/// is throttled before it reaches SwiftUI state.
actor DownloadEngine {
    private let fileManager = FileManager.default

    func download(
        request: URLRequest,
        destination: URL,
        allowCellular: Bool = true,
        onProgress: @escaping @Sendable (DownloadByteProgress) async -> Void
    ) async throws -> HTTPURLResponse {
        var mutableRequest = request
        mutableRequest.allowsCellularAccess = allowCellular
        // A media host that is handed no identity at all answers a large share of requests with
        // an error page, so the transfer carries the same identity that found the address.
        if mutableRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            mutableRequest.setValue(FetchProfile.browser.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if mutableRequest.value(forHTTPHeaderField: "Accept") == nil {
            mutableRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        }

        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let coordinator = DownloadCoordinator(destination: destination, onProgress: onProgress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowCellular
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: coordinator, delegateQueue: nil)
        // `URLSession` keeps a strong reference to its delegate until it is invalidated, so the
        // session is always finished, on every path, including cancellation.
        defer { session.finishTasksAndInvalidate() }

        do {
            return try await coordinator.run(session: session, request: mutableRequest)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}

/// Bridges `URLSession`'s delegate callbacks to one `async` call. It owns the download task so
/// task cancellation reaches the loader, and it moves the finished file into place inside the
/// delegate callback, which is the only point where that temporary file still exists.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (DownloadByteProgress) async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var lastReport = Date.distantPast
    /// Reporting on every callback would thrash SwiftUI; a quarter second is well under the
    /// interval at which a progress bar reads as smooth.
    private static let reportInterval: TimeInterval = 0.25

    init(destination: URL, onProgress: @escaping @Sendable (DownloadByteProgress) async -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(session: URLSession, request: URLRequest) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.lock()
                self.continuation = continuation
                let downloadTask = session.downloadTask(with: request)
                self.task = downloadTask
                lock.unlock()
                downloadTask.resume()
            }
        } onCancel: {
            lock.lock()
            let cancelled = task
            lock.unlock()
            cancelled?.cancel()
        }
    }

    private func finish(with result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        switch result {
        case .success(let response): pending.resume(returning: response)
        case .failure(let error): pending.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        lock.lock()
        let due = Date().timeIntervalSince(lastReport) >= Self.reportInterval
        if due { lastReport = Date() }
        lock.unlock()
        guard due else { return }
        let report = onProgress
        Task { await report(DownloadByteProgress(completedBytes: totalBytesWritten, expectedBytes: expected)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The loader deletes `location` as soon as this method returns, so the move happens here.
        do {
            let manager = FileManager.default
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: location, to: destination)
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let asCancellation = (error as? URLError)?.code == .cancelled
            finish(with: .failure(asCancellation ? CancellationError() : error))
            return
        }
        lock.lock()
        let failedMove = moveError
        lock.unlock()
        if let failedMove {
            finish(with: .failure(failedMove))
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            finish(with: .failure(ResolverError.invalidResponse))
            return
        }
        guard (200 ... 299).contains(response.statusCode) else {
            // A precise status is the difference between "try again later" and "this is gone".
            finish(with: .failure(DownloadEngine.error(for: response.statusCode)))
            return
        }
        let expected = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : nil
        let received = task.countOfBytesReceived
        let report = onProgress
        Task { await report(DownloadByteProgress(completedBytes: received, expectedBytes: expected ?? received)) }
        finish(with: .success(response))
    }
}

extension DownloadEngine {
    /// Maps a transfer status onto the message the person actually needs. Collapsing every
    /// status into one generic failure is what made an expired link and a private post read the
    /// same way.
    static func error(for statusCode: Int) -> ResolverError {
        switch statusCode {
        case 401: .authenticationRequired
        case 403: .expiredMediaURL
        case 404, 410: .contentNotFound
        case 429: .rateLimited
        case 500 ... 599: .networkFailure
        default: .networkFailure
        }
    }
}
