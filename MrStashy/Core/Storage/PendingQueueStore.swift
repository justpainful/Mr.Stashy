import Foundation

struct PendingQueueRequest: Codable, Sendable, Identifiable {
    var id: UUID
    var sourceURL: URL
    var selectedOrderIndices: Set<Int>
    var mode: QueueItem.SaveMode
}

actor PendingQueueStore {
    private let fileManager = FileManager.default
    private let overrideFileURL: URL?

    init(fileURL: URL? = nil) {
        overrideFileURL = fileURL
    }

    private var fileURL: URL {
        if let overrideFileURL { return overrideFileURL }
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stashy/Queue/pending.json", isDirectory: false)
    }

    func load() -> [PendingQueueRequest] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.stashy.decode([PendingQueueRequest].self, from: data)) ?? []
    }

    func upsert(_ request: PendingQueueRequest) throws {
        var requests = load()
        requests.removeAll { $0.id == request.id }
        requests.append(request)
        try write(requests)
    }

    func remove(id: UUID) throws {
        var requests = load()
        requests.removeAll { $0.id == id }
        try write(requests)
    }

    private func write(_ requests: [PendingQueueRequest]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.stashy.encode(requests).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
