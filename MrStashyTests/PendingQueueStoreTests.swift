import Foundation
import Testing
@testable import MrStashy

struct PendingQueueStoreTests {
    @Test func persistsOnlyReResolvableQueueMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingQueueStore(fileURL: root.appendingPathComponent("pending.json"))
        let source = try #require(URL(string: "https://cdn.example.test/file.mp4"))
        let request = PendingQueueRequest(
            id: UUID(), sourceURL: source, selectedOrderIndices: [0, 2], mode: .fullPost
        )

        try await store.upsert(request)
        let restored = await store.load()
        #expect(restored.count == 1)
        #expect(restored.first?.sourceURL == source)
        #expect(restored.first?.selectedOrderIndices == [0, 2])

        try await store.remove(id: request.id)
        let empty = await store.load()
        #expect(empty.isEmpty)
    }
}
