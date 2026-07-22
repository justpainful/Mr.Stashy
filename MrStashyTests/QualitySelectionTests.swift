import Foundation
import Testing
@testable import MrStashy

struct QualitySelectionTests {
    @Test func explicitDataSaverChoiceSelectsTheSmallVariant() async throws {
        let large = try variant(url: "https://cdn.example.test/large.mp4", width: 1920, height: 1080, bytes: 8_000_000)
        let small = try variant(url: "https://cdn.example.test/small.mp4", width: 640, height: 360, bytes: 900_000)
        let media = ResolvedMedia(
            id: UUID(), orderIndex: 0, type: .video, thumbnailURL: nil,
            variants: [small, large], width: 1920, height: 1080, duration: 10, altText: nil
        )
        let store = ArchiveStore()
        let original = await store.selectedVariant(for: media, quality: .original)
        let dataSaver = await store.selectedVariant(for: media, quality: .dataSaver)

        #expect(original?.id == large.id)
        #expect(dataSaver?.id == small.id)
    }

    private func variant(url: String, width: Int, height: Int, bytes: Int64) throws -> MediaVariant {
        MediaVariant(
            id: UUID(), url: try #require(URL(string: url)), headers: [:], expirationDate: nil,
            width: width, height: height, bitrate: nil, fps: nil, isHDR: nil, codec: "h264",
            container: "mp4", hasSeparateAudio: false, estimatedBytes: bytes,
            qualityLabel: "source", cleanliness: .original
        )
    }
}
