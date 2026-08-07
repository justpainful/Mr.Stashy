import AVFoundation
import ImageIO
import SwiftUI
import UIKit

// Shared visual thumbnails. Every screen that shows media — the Catch preview, the Review
// grid, and the Library grid — draws it through these two views, so a person always sees the
// actual picture or a video's first frame instead of a row of words describing it.

extension MediaType {
    /// A per-kind tint used for placeholders and badges, so an item that has no thumbnail yet
    /// still reads as "video" or "photo" at a glance rather than as an anonymous grey box.
    var tint: Color {
        switch self {
        case .photo: StashyTheme.aqua
        case .video: StashyTheme.lavender
        case .gif: StashyTheme.butter
        case .audio: StashyTheme.pink
        }
    }

    var shortLabel: String { L10n.value("media.\(rawValue)") }
}

/// How a thumbnail's decode ended. A failure has to be a state of its own: treating it as
/// "still loading" is what left a spinner turning forever over a file that would never decode.
private enum ThumbnailLoad {
    case loading
    case loaded(UIImage)
    case failed
}

// MARK: - Remote thumbnail (a resolved post, before it is saved)

/// Draws the preview a source already published for one piece of media. A photo is its own
/// preview; a video or GIF uses the poster frame the source exposes. When neither loads, the
/// kind's glyph stands in so the card is never blank.
struct RemoteMediaThumbnail: View {
    let media: ResolvedMedia
    var cornerRadius: CGFloat = 18

    private var previewURL: URL? {
        if let thumbnail = media.thumbnailURL { return thumbnail }
        // A still image is its own poster, so the highest variant doubles as the preview.
        if media.type == .photo || media.type == .gif { return media.highestVariant?.url }
        return nil
    }

    var body: some View {
        ThumbnailFrame(type: media.type, cornerRadius: cornerRadius) {
            if let previewURL {
                AsyncImage(url: previewURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        MediaGlyph(type: media.type)
                    @unknown default:
                        MediaGlyph(type: media.type)
                    }
                }
            } else {
                MediaGlyph(type: media.type)
            }
        }
        .overlay { PlayOverlay(type: media.type) }
        .overlay(alignment: .bottomTrailing) {
            if let badge = badgeText { ThumbnailBadge(text: badge) }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var badgeText: String? {
        switch media.type {
        case .video: return media.duration.map(ThumbnailBadge.durationText)
        case .gif: return L10n.value("media.gif")
        case .audio: return media.type.shortLabel
        case .photo: return nil
        }
    }

    /// The kind, and a video's length, so a duration that is only drawn as a badge is still
    /// something VoiceOver reports.
    private var accessibilityLabel: String {
        guard let duration = media.duration, media.type == .video else { return media.type.shortLabel }
        return "\(media.type.shortLabel), \(ThumbnailBadge.spokenDuration(duration))"
    }
}

// MARK: - Local thumbnail (an archived file already on the device)

/// Draws a thumbnail from a file already saved on the device. Stills are downsampled with
/// ImageIO and a video's first frame is pulled with AVFoundation, both off the main thread, so
/// a grid of many items scrolls without decoding anything at full resolution on the UI.
struct LocalMediaThumbnail: View {
    let url: URL
    let type: MediaType
    var cornerRadius: CGFloat = 18
    /// A saved video's length, so the grid shows it the same way the review does.
    var duration: TimeInterval?
    @State private var load: ThumbnailLoad = .loading

    var body: some View {
        ThumbnailFrame(type: type, cornerRadius: cornerRadius) {
            switch load {
            case .loaded(let image):
                Image(uiImage: image).resizable().scaledToFill()
            case .failed:
                MediaGlyph(type: type)
            case .loading:
                if type == .audio {
                    MediaGlyph(type: type)
                } else {
                    ProgressView()
                }
            }
        }
        .overlay { PlayOverlay(type: type) }
        .overlay(alignment: .bottomTrailing) {
            if let badge = badgeText { ThumbnailBadge(text: badge) }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityLabel))
        // The decode runs inside a Task whose `.value` carries the result back, the same
        // offloading the archived-media preview already uses. It keeps a full-resolution decode
        // off the main thread while satisfying the compiler's isolation checks for UIImage.
        .task(id: url) {
            load = .loading
            switch type {
            case .photo, .gif:
                let image = await Task.detached(priority: .userInitiated) {
                    MediaThumbnailRenderer.stillImage(url: url, maxPixelSize: 700)
                }.value
                load = image.map(ThumbnailLoad.loaded) ?? .failed
            case .video:
                let image = await Task.detached(priority: .userInitiated) {
                    await MediaThumbnailRenderer.videoFrame(url: url, maxPixelSize: 700)
                }.value
                load = image.map(ThumbnailLoad.loaded) ?? .failed
            case .audio:
                load = .failed
            }
        }
    }

    private var badgeText: String? {
        switch type {
        case .video: return duration.map(ThumbnailBadge.durationText)
        case .gif: return L10n.value("media.gif")
        case .audio: return type.shortLabel
        case .photo: return nil
        }
    }

    private var accessibilityLabel: String {
        guard let duration, type == .video else { return type.shortLabel }
        return "\(type.shortLabel), \(ThumbnailBadge.spokenDuration(duration))"
    }
}

// MARK: - Building blocks

/// The tinted, clipped container every thumbnail shares.
///
/// The gradient is the size authority and the media is an overlay on top of it. That ordering is
/// the whole point: `scaledToFill` deliberately reports a size *larger* than the space it was
/// offered, and a `ZStack` adopts the largest child, so the old arrangement let a portrait photo
/// report a 76×135 thumbnail for a 76×76 slot — which is why images painted over the rows and
/// text beneath them. An overlay never grows its parent, so the frame now wins and the clip that
/// follows it does real work.
private struct ThumbnailFrame<Content: View>: View {
    let type: MediaType
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        LinearGradient(
            colors: [type.tint.opacity(0.28), type.tint.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { content }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(StashyTheme.hairline, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct MediaGlyph: View {
    let type: MediaType
    var body: some View {
        Image(systemName: type.systemImage)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(type.tint)
            .accessibilityHidden(true)
    }
}

private struct PlayOverlay: View {
    let type: MediaType
    var body: some View {
        if type == .video {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white, .black.opacity(0.38))
                .shadow(color: .black.opacity(0.25), radius: 4)
                .accessibilityHidden(true)
        }
    }
}

struct ThumbnailBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
            // The badge duplicates what the thumbnail's own label already says.
            .accessibilityHidden(true)
    }

    /// A compact m:ss (or h:mm:ss) for a duration badge.
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// The same length, said the way a screen reader should say it — "2 minutes, 14 seconds" —
    /// rather than spelling out the digits of "2:14".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return durationText(0) }
        return Duration.seconds(Int(seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(L10n.activeLocale))
    }
}

// MARK: - Rendering

enum MediaThumbnailRenderer {
    static func stillImage(url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func videoFrame(url: URL, maxPixelSize: Int) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // A hair past the first frame; some containers have no keyframe exactly at zero. The
        // tolerances let the generator settle on the nearest one it can find rather than failing
        // outright and leaving the tile with no picture at all.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        do {
            let result = try await generator.image(at: time)
            return UIImage(cgImage: result.image)
        } catch {
            // A clip whose first second will not decode may still yield its very first frame.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .positiveInfinity
            guard let fallback = try? await generator.image(at: .zero) else { return nil }
            return UIImage(cgImage: fallback.image)
        }
    }
}
