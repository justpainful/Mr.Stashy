import Foundation
import Testing
@testable import MrStashy

struct LibraryOrganizationTests {
    @Test func localPinsAndCollectionMembershipRoundTripWithoutAnAccount() throws {
        let archiveID = UUID()
        let collection = StashCollection(name: "Weekend ideas")
        let state = LibraryOrganization(
            collections: [collection],
            pinnedArchiveIDs: [archiveID],
            archiveIDsByCollection: [collection.id: [archiveID]]
        )

        let decoded = try JSONDecoder.stashy.decode(
            LibraryOrganization.self,
            from: JSONEncoder.stashy.encode(state)
        )

        #expect(decoded.pinnedArchiveIDs == [archiveID])
        #expect(decoded.collections.map(\.id) == [collection.id])
        #expect(decoded.collections.map(\.name) == [collection.name])
        #expect(decoded.collections.map(\.symbol) == [collection.symbol])
        #expect(decoded.contains(archiveID, in: collection.id))
    }
}
