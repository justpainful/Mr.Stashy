import Foundation
import Testing
@testable import MrStashy

struct PendingSharePayloadTests {
    @Test func storesUniqueCanonicalUrlsAndPreservesAllDistinctLinks() throws {
        let suiteName = "PendingSharePayloadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try #require(URL(string: "https://example.com/post1"))
        let second = try #require(URL(string: "https://example.com/post2"))
        let duplicate = try #require(URL(string: "https://example.com/post1#fragment"))

        PendingShareStore.enqueue([first, second, duplicate], defaults: defaults)

        let links = PendingShareStore.consumePendingURLs(defaults: defaults)
        #expect(links.count == 2)
        #expect(links.contains(first))
        #expect(links.contains(second))
        #expect(PendingShareStore.consumePendingURLs(defaults: defaults).isEmpty)
    }
}
