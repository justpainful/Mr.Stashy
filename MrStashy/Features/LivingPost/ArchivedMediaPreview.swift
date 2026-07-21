import AVKit
import ImageIO
import SwiftUI
import UIKit

struct ArchivedMediaPreview: View {
    let url: URL
    let type: MediaType

    var body: some View {
        switch type {
        case .photo, .gif:
            ArchivedImagePreview(url: url)
        case .video:
            ArchivedVideoPreview(url: url)
        case .audio:
            Link(destination: url) {
                Label(String(localized: "livingPost.openMedia"), systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }
}

private struct ArchivedImagePreview: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(Text(String(localized: "livingPost.localImage")))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .task(id: url) {
            // ImageIO asks for a bounded thumbnail, preventing a full-resolution render in
            // the scrolling Living Post hierarchy.
            image = LocalImageThumbnail.make(url: url, maxPixelSize: 1_600)
        }
    }
}

private struct ArchivedVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 220, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onDisappear { player.pause() }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .task(id: url) { player = AVPlayer(url: url) }
    }
}

private enum LocalImageThumbnail {
    static func make(url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
