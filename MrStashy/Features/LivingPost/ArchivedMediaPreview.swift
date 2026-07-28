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
                Label(L10n.value("livingPost.openMedia"), systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }
}

private struct ArchivedGIFPreview: UIViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
        var task: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        return imageView
    }

    // Decoding every frame of a GIF is expensive, and doing it inline on each SwiftUI update
    // froze the Living Post while scrolling. Frames are decoded once, off the main thread, and
    // only when the file being shown actually changes.
    func updateUIView(_ imageView: UIImageView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        context.coordinator.task?.cancel()
        imageView.stopAnimating()
        imageView.image = nil
        let source = url
        context.coordinator.task = Task { [weak imageView] in
            // A child task, not a detached one, so leaving the screen actually stops the decode
            // rather than leaving it to finish frames nobody will see.
            let animation = await Task(priority: .userInitiated) {
                AnimatedGIF.make(url: source)
            }.value
            guard !Task.isCancelled, let imageView else { return }
            imageView.image = animation
            if animation?.images != nil { imageView.startAnimating() }
        }
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        imageView.stopAnimating()
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
                    .accessibilityLabel(Text(L10n.value("livingPost.localImage")))
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
    /// A long GIF is bounded so a pathological file cannot decode thousands of frames.
    private static let maximumFrames = 300

    static func make(url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return LocalImageThumbnail.make(url: url, maxPixelSize: 1_600) }
        // Frames are downsampled like the still path. Decoding them at full resolution was an
        // unintended asymmetry: the same view already caps a single image at 1600px.
        let frameOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024
        ]
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0 ..< min(count, maximumFrames) {
            if Task.isCancelled { return nil }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, frameOptions as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(delay, 0.02)
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
