import AVKit
import ImageIO
import SwiftUI
import UIKit

struct ArchivedMediaPreview: View {
    let url: URL
    let type: MediaType

    var body: some View {
        switch type {
        case .photo:
            ArchivedImagePreview(url: url)
        case .gif:
            ArchivedGIFPreview(url: url)
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

private struct ArchivedGIFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.image = AnimatedGIF.make(url: url)
        imageView.startAnimating()
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.image = AnimatedGIF.make(url: url)
        imageView.startAnimating()
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

private enum AnimatedGIF {
    static func make(url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return LocalImageThumbnail.make(url: url, maxPixelSize: 1_600) }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0 ..< count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(delay, 0.02)
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
