import Foundation
import Photos

enum PhotoLibrarySaver {
    static func save(url: URL, type: MediaType) async throws {
        guard type != .audio else { throw PhotoLibrarySaveError.unsupportedMedia }
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else { throw PhotoLibrarySaveError.authorizationDenied }
        try await PHPhotoLibrary.shared().performChanges {
            switch type {
            case .photo, .gif:
                // Supplying the original resource keeps GIF bytes intact instead of relying on
                // an image decode that can flatten animation.
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            case .video:
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            case .audio:
                return
            }
        }
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        // Once the choice has been made, answer from it directly. Suspending on the system
        // prompt here holds a download permit, which parked every other queued transfer behind
        // an alert the person may not have noticed.
        let existing = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard existing == .notDetermined else { return existing }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in continuation.resume(returning: status) }
        }
    }
}

enum PhotoLibrarySaveError: LocalizedError {
    case authorizationDenied, unsupportedMedia

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: L10n.value("photos.error.authorization")
        case .unsupportedMedia: L10n.value("photos.error.unsupported")
        }
    }
}
