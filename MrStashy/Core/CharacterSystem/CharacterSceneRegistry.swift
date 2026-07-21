import Foundation

enum CharacterAsset: String, CaseIterable, Identifiable {
    case humanA, humanB, orbit, bloom, sprout, round, geo, cloud
    var id: String { rawValue }
}

enum CharacterScene: String, CaseIterable {
    case onboardingPaste, onboardingArchive, catchHero, resultsReady, queueEmpty, queueComplete, libraryEmpty, livingPost, settingsHero, textCard, error, collection
}

enum CharacterSceneRegistry {
    private static let mapping: [CharacterScene: [CharacterAsset]] = [
        .onboardingPaste: [.humanA, .orbit], .onboardingArchive: [.humanB, .bloom],
        .catchHero: [.sprout, .round], .resultsReady: [.geo, .cloud],
        .queueEmpty: [.bloom], .queueComplete: [.humanB], .libraryEmpty: [.orbit],
        .livingPost: [.humanA], .settingsHero: [.geo], .textCard: [.cloud],
        .error: [.round], .collection: [.sprout]
    ]

    static func assets(for scene: CharacterScene) -> [CharacterAsset] { mapping[scene, default: []] }
}
