import ImageIO
import SwiftUI
import UIKit

/// The palette from Docs/DESIGN.md. One accent, paper and ink, and the two verdict colours.
enum Theme {
    static let paper = Color(light: UIColor(red: 0.957, green: 0.945, blue: 0.922, alpha: 1), dark: UIColor(red: 0.059, green: 0.067, blue: 0.075, alpha: 1))
    static let card = Color(light: .white, dark: UIColor(red: 0.102, green: 0.114, blue: 0.129, alpha: 1))
    static let cardRaised = Color(light: UIColor(red: 0.98, green: 0.973, blue: 0.957, alpha: 1), dark: UIColor(red: 0.141, green: 0.157, blue: 0.176, alpha: 1))
    static let ink = Color(light: UIColor(red: 0.082, green: 0.09, blue: 0.102, alpha: 1), dark: UIColor(red: 0.941, green: 0.933, blue: 0.914, alpha: 1))
    static let muted = Color(light: UIColor(red: 0.431, green: 0.451, blue: 0.475, alpha: 1), dark: UIColor(red: 0.62, green: 0.64, blue: 0.66, alpha: 1))
    static let rule = Color(light: UIColor(red: 0.871, green: 0.855, blue: 0.824, alpha: 1), dark: UIColor(red: 0.2, green: 0.216, blue: 0.235, alpha: 1))
    static let amber = Color(light: UIColor(red: 0.788, green: 0.455, blue: 0.11, alpha: 1), dark: UIColor(red: 0.91, green: 0.6, blue: 0.25, alpha: 1))
    static let amberSoft = Color(light: UIColor(red: 0.788, green: 0.455, blue: 0.11, alpha: 0.14), dark: UIColor(red: 0.91, green: 0.6, blue: 0.25, alpha: 0.2))
    static let verified = Color(light: UIColor(red: 0.184, green: 0.49, blue: 0.306, alpha: 1), dark: UIColor(red: 0.36, green: 0.72, blue: 0.5, alpha: 1))
    static let warn = Color(light: UIColor(red: 0.706, green: 0.169, blue: 0.118, alpha: 1), dark: UIColor(red: 0.93, green: 0.42, blue: 0.37, alpha: 1))

    static let cornerRadius: CGFloat = 14

    /// Brand tints for the small platform glyphs; never used as surfaces.
    static func tint(for platform: Platform) -> Color {
        switch platform {
        case .tikTok: Color(red: 0.0, green: 0.95, blue: 0.92)
        case .youTube: Color(red: 1.0, green: 0.0, blue: 0.0)
        case .instagram: Color(red: 0.88, green: 0.19, blue: 0.42)
        case .threads: ink
        case .x: ink
        case .reddit: Color(red: 1.0, green: 0.27, blue: 0.0)
        case .bluesky: Color(red: 0.07, green: 0.52, blue: 1.0)
        case .pinterest: Color(red: 0.9, green: 0.0, blue: 0.14)
        case .snapchat: Color(red: 0.95, green: 0.85, blue: 0.0)
        case .kick: Color(red: 0.32, green: 1.0, blue: 0.0)
        case .tumblr: Color(red: 0.2, green: 0.27, blue: 0.36)
        case .imgur: Color(red: 0.1, green: 0.73, blue: 0.36)
        case .discord: Color(red: 0.35, green: 0.4, blue: 0.95)
        case .web: muted
        }
    }
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - Reusable pieces

/// The signature element: a monospaced statement of what a file is.
struct SpecLine: View {
    var parts: [String]
    var verified = false
    var tone: Color = Theme.muted

    init(_ parts: [String?], verified: Bool = false, tone: Color = Theme.muted) {
        self.parts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        self.verified = verified
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(parts.map { L10n.isolated($0) }.joined(separator: "  ·  "))
                .font(.system(.footnote, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if verified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.verified)
                    .accessibilityLabel(L10n.value("spec.verified"))
            }
        }
    }
}

struct PlatformGlyph: View {
    var platform: Platform
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.cardRaised)
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
            Image(systemName: platform.systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Theme.tint(for: platform))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CardBackground: ViewModifier {
    var raised = false
    func body(content: Content) -> some View {
        content
            .background(raised ? Theme.cardRaised : Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
    }
}

extension View {
    func card(raised: Bool = false) -> some View { modifier(CardBackground(raised: raised)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.amber.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.cardRaised.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
    }
}

/// One sentence and one action; nothing else belongs on an empty screen.
struct EmptyNotice: View {
    var symbol: String
    var text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.muted)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 220)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Local images

/// Decodes a downsampled copy of a file on disk, off the main thread, and caches it.
struct LocalImage: View {
    var url: URL?
    var maxPixels: CGFloat = 600
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Theme.cardRaised
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ImageCache.shared.image(for: url, maxPixels: maxPixels)
        }
    }
}

actor ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 400 }

    func image(for url: URL, maxPixels: CGFloat) -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixels))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels * 2,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A remote thumbnail that never blocks the layout and never shows a broken-image glyph.
struct RemoteThumbnail: View {
    var url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Theme.cardRaised
            }
        }
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        return L10n.byteCount(value)
    }

    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func speed(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 1024 else { return nil }
        return L10n.byteCount(Int64(bytesPerSecond)) + "/s"
    }
}
