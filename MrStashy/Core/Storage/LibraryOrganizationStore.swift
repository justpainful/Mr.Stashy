import Foundation

/// Local-only organization metadata. Archives remain portable `.stash` packages; pins and
/// collections deliberately stay on this device and never require an account or a server.
struct StashCollection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, symbol: String = "square.stack.3d.up.fill", createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.createdAt = createdAt
    }
}

struct LibraryOrganization: Codable, Sendable {
    var collections: [StashCollection] = []
    var pinnedArchiveIDs: Set<UUID> = []
    var archiveIDsByCollection: [UUID: Set<UUID>] = [:]

    func contains(_ archiveID: UUID, in collectionID: UUID) -> Bool {
        archiveIDsByCollection[collectionID]?.contains(archiveID) == true
    }
}

actor LibraryOrganizationStore {
    private let fileManager = FileManager.default

    private var stateURL: URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stashy", isDirectory: true)
        return root.appendingPathComponent("Organization.json")
    }

    func load() -> LibraryOrganization {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder.stashy.decode(LibraryOrganization.self, from: data)
        else { return LibraryOrganization() }
        return state
    }

    func save(_ state: LibraryOrganization) throws {
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.stashy.encode(state).write(to: stateURL, options: .atomic)
    }
}
