import Foundation
import Photos

enum PhotoLibrarySaver {
    static func save(url: URL, kind: MediaKind) async throws {
        guard kind != .audio else { return }
        let status = await authorization()
        guard status == .authorized || status == .limited else { throw StashyError.storage }
        try await PHPhotoLibrary.shared().performChanges {
            switch kind {
            case .photo, .gif:
                // Adding the file as a resource keeps GIF frames and HEIC data intact.
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            case .video:
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            case .audio:
                break
            }
        }
    }

    static func authorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }
}
