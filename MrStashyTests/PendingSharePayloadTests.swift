import Foundation
import Testing
@testable import MrStashy

struct PendingSharePayloadTests {
    @Test func storesOnlyOneCanonicalCopyAndConsumesItOnce() throws {
        let suiteName = "PendingSharePayloadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try #require(URL(string: "https://example.com/post#first"))
        let second = try #require(URL(string: "https://example.com/post#second"))

        PendingShareStore.enqueue([first, second], defaults: defaults)

        let links = PendingShareStore.consumePendingURLs(defaults: defaults)
        #expect(links == [first])
        #expect(PendingShareStore.consumePendingURLs(defaults: defaults).isEmpty)
    }
}
