import AVKit
import ImageIO
import SwiftUI
import UIKit

/// One archived file, shown at its real shape.
///
/// Every kind previously answered to a hard-coded height band, which letterboxed portrait video
/// and cropped tall photographs. Each preview now measures the file it is showing and lays out to
/// that, and video and audio play through the rebuilt players rather than a bare `VideoPlayer` or
/// a link out to another app.
struct ArchivedMediaPreview: View {
    let url: URL
    let type: MediaType
    /// A ratio already known from the manifest, used before the file reports its own.
    var declaredAspect: CGFloat?
    /// Opens the dedicated full-screen player. When `nil`, video plays inline only.
    var onExpand: ((URL) -> Void)?
    var accessibilityText: String?
    /// A video's length, shown on the poster when the preview cannot be played.
    var duration: TimeInterval?
    /// Whether this preview can be touched. A context-menu peek cannot: iOS renders it as a
    /// static picture, so putting a player there produced transport controls that did nothing.
    var isInteractive = true

    var body: some View {
        switch type {
        case .photo:
            ArchivedImagePreview(url: url, declaredAspect: declaredAspect, alternativeText: accessibilityText)
        case .gif:
            ArchivedGIFPreview(url: url, declaredAspect: declaredAspect, alternativeText: accessibilityText)
        case .video:
            if isInteractive {
                InlineVideoPlayer(url: url, declaredAspect: declaredAspect, onExpand: onExpand)
            } else {
                LocalMediaThumbnail(url: url, type: .video, duration: duration)
                    .aspectRatio(VideoGeometry.clamped(declaredAspect), contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        case .audio:
            if isInteractive {
                AudioPlaybackView(url: url, title: accessibilityText)
            } else {
                Label(accessibilityText ?? L10n.value("media.audio"), systemImage: "waveform")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }
}

// MARK: - Still image

private struct ArchivedImagePreview: View {
    let url: URL
    var declaredAspect: CGFloat?
    var alternativeText: String?
    @State private var image: UIImage?

    private var aspect: CGFloat {
        if let image, image.size.width > 0, image.size.height > 0 {
            return min(max(image.size.width / image.size.height, 0.4), 2.4)
        }
        return VideoGeometry.clamped(declaredAspect, fallback: 3.0 / 4.0)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The frame follows the picture rather than a fixed 420pt ceiling, so a tall photograph
        // is shown whole instead of being squeezed into a landscape band.
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: url) {
            // ImageIO asks for a bounded thumbnail, preventing a full-resolution render in
            // the scrolling Living Post hierarchy. The decode runs off the main thread so a
            // large photograph does not stall the scroll that revealed it.
            image = await Task.detached(priority: .userInitiated) {
                LocalImageThumbnail.make(url: url, maxPixelSize: 1_600)
            }.value
        }
        .accessibilityElement()
        .accessibilityLabel(Text(alternativeText?.isEmpty == false ? alternativeText! : L10n.value("livingPost.localImage")))
    }
}

// MARK: - Animated GIF

private struct ArchivedGIFPreview: View {
    let url: URL
    var declaredAspect: CGFloat?
    var alternativeText: String?
    @State private var animation: AnimatedGIF.Result?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var aspect: CGFloat {
        if let size = animation?.image.size, size.width > 0, size.height > 0 {
            return min(max(size.width / size.height, 0.4), 2.4)
        }
        return VideoGeometry.clamped(declaredAspect, fallback: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let animation {
                    // Reduce Motion is a request not to animate. Showing the first frame honours
                    // it while still showing the person what they saved.
                    GIFImageView(image: animation.image, animates: !reduceMotion)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // A long animation is capped so a pathological file cannot decode forever. Saying so
            // is the difference between a deliberate limit and a file that looks truncated.
            if animation?.isTruncated == true {
                Text(L10n.value("media.gifTruncated"))
                    .font(.caption2)
                    .foregroundStyle(StashyTheme.inkSecondary)
            }
        }
        .task(id: url) {
            animation = await Task.detached(priority: .userInitiated) {
                AnimatedGIF.make(url: url)
            }.value
        }
        .accessibilityElement()
        .accessibilityLabel(Text(alternativeText?.isEmpty == false ? alternativeText! : L10n.value("media.gif")))
    }
}

/// A `UIImageView` is still the only view that plays a multi-frame `UIImage`, so the animated
/// case wraps one. It carries no decode work of its own: the frames arrive already built.
private struct GIFImageView: UIViewRepresentable {
    let image: UIImage
    let animates: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        // Without this, the image view reports its intrinsic pixel size and a large GIF pushes
        // the whole card wider than the screen.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image { view.image = image }
        if animates, image.images != nil {
            if !view.isAnimating { view.startAnimating() }
        } else {
            view.stopAnimating()
            if let first = image.images?.first { view.image = first }
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: ()) {
        view.stopAnimating()
        view.image = nil
    }
}

enum LocalImageThumbnail {
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

enum AnimatedGIF {
    struct Result {
        let image: UIImage
        /// Whether frames past the cap were dropped, so the view can say so.
        let isTruncated: Bool
    }

    /// A long GIF is bounded so a pathological file cannot decode thousands of frames.
    private static let maximumFrames = 300

    static func make(url: URL) -> Result? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            return LocalImageThumbnail.make(url: url, maxPixelSize: 1_600).map { Result(image: $0, isTruncated: false) }
        }
        // Frames are downsampled like the still path. Decoding them at full resolution was an
        // unintended asymmetry: the same view already caps a single image at 1600px.
        let frameOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024
        ]
        var frames: [UIImage] = []
        var delays: [TimeInterval] = []
        for index in 0 ..< min(count, maximumFrames) {
            if Task.isCancelled { return nil }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, frameOptions as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            delays.append(max(delay, 0.02))
        }
        guard !frames.isEmpty else { return nil }

        // `UIImage.animatedImage(with:duration:)` gives every frame the same screen time, so a
        // GIF that holds one frame for a second and flicks through the rest — which is most of
        // them — played at a flat average and lost its timing entirely. Repeating each frame in
        // proportion to its own delay reproduces the real cadence with the only control the API
        // offers. The tick is bounded so a pathological file cannot expand into a huge array.
        let tick = max(delays.min() ?? 0.05, 0.02)
        var timed: [UIImage] = []
        timed.reserveCapacity(frames.count)
        for (frame, delay) in zip(frames, delays) {
            let repeats = min(max(Int((delay / tick).rounded()), 1), 40)
            for _ in 0 ..< repeats {
                timed.append(frame)
                if timed.count >= 1_200 { break }
            }
            if timed.count >= 1_200 { break }
        }
        guard let animated = UIImage.animatedImage(with: timed, duration: tick * Double(timed.count)) else { return nil }
        return Result(image: animated, isTruncated: count > maximumFrames)
    }
}
