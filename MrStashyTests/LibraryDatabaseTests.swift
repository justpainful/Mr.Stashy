import Foundation
import Testing
@testable import MrStashy

struct LibraryDatabaseTests {
    @Test func migratedIndexPersistsAndSearchesArchiveMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = LibraryDatabase()
        let first = ArchivedPostSummary(
            id: UUID(), platform: .directMedia, author: "Ada Lovelace", text: "A small archive about analytical engines", mediaCount: 1, savedAt: .now, localFolderName: "first"
        )
        let second = ArchivedPostSummary(
            id: UUID(), platform: .directMedia, author: "Grace Hopper", text: "Compiler notes", mediaCount: 2, savedAt: .now.addingTimeInterval(-10), localFolderName: "second"
        )

        try await database.migrate(at: root.appendingPathComponent("library.sqlite"))
        try await database.upsert(first)
        try await database.upsert(second)

        let matches = try await database.summaries(matching: "analytical Ada")
        #expect(matches.map(\.id) == [first.id])
    }
}
