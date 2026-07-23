import SwiftUI

enum StashyTheme {
    static let cream = Color(red: 1.00, green: 0.97, blue: 0.94)
    static let charcoal = Color(red: 0.14, green: 0.12, blue: 0.18)
    static let lavender = Color(red: 0.45, green: 0.37, blue: 0.84)
    static let butter = Color(red: 1.00, green: 0.75, blue: 0.31)
    static let pink = Color(red: 0.94, green: 0.34, blue: 0.47)
    static let aqua = Color(red: 0.34, green: 0.77, blue: 0.84)
    // Kept as the semantic success/action token for compatibility; it is indigo, not green.
    static let green = Color(red: 0.39, green: 0.31, blue: 0.76)
    static let darkSurface = Color(red: 0.10, green: 0.09, blue: 0.14)
    static let surface = Color(uiColor: .secondarySystemBackground)
}

struct StashyIllustration: View {
    let name: String
    var maxHeight: CGFloat = 220

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .accessibilityHidden(true)
    }
}

/// A local source badge. Brand artwork is bundled with the app so the capture flow
/// remains useful before a network request is made.
struct PlatformIcon: View {
    let platform: Platform
    var size: CGFloat = 32

    var body: some View {
        Group {
            if platform == .directMedia {
                Image(systemName: platform.sourceStyle.symbol)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundStyle(platform.sourceStyle.accent)
                    .background(platform.sourceStyle.accent.opacity(0.16))
            } else {
                Image(platform.rawValue)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 0.5)
        }
        .accessibilityLabel(Text(L10n.value(platform.titleKey)))
    }
}

struct SourceStyle {
    let accent: Color
    let symbol: String
}

extension Platform {
    static let quickCapturePlatforms: [Platform] = [
        .tikTok, .instagram, .x, .youTube, .pinterest, .snapchat,
        .kick, .threads, .tumblr, .imgur, .discord
    ]

    var sourceStyle: SourceStyle {
        switch self {
        case .tikTok: SourceStyle(accent: StashyTheme.aqua, symbol: "music.note")
        case .instagram: SourceStyle(accent: StashyTheme.pink, symbol: "camera")
        case .x: SourceStyle(accent: Color(red: 0.11, green: 0.61, blue: 0.96), symbol: "at")
        case .pinterest: SourceStyle(accent: Color(red: 0.82, green: 0.15, blue: 0.19), symbol: "pin")
        case .snapchat: SourceStyle(accent: StashyTheme.butter, symbol: "bolt")
        case .kick: SourceStyle(accent: Color(red: 0.24, green: 0.74, blue: 0.38), symbol: "play.rectangle")
        case .threads: SourceStyle(accent: StashyTheme.charcoal, symbol: "at")
        case .tumblr: SourceStyle(accent: Color(red: 0.16, green: 0.26, blue: 0.36), symbol: "text.bubble")
        case .imgur: SourceStyle(accent: Color(red: 0.15, green: 0.68, blue: 0.43), symbol: "photo.on.rectangle")
        case .youTube: SourceStyle(accent: Color(red: 0.91, green: 0.10, blue: 0.12), symbol: "play.rectangle.fill")
        case .discord: SourceStyle(accent: StashyTheme.lavender, symbol: "bubble.left.and.bubble.right")
        case .directMedia: SourceStyle(accent: StashyTheme.aqua, symbol: "link")
        }
    }
}

struct StashyBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        (colorScheme == .dark ? StashyTheme.darkSurface : StashyTheme.cream)
            .ignoresSafeArea()
    }
}

struct FeatureHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let titleKey: String
    let subtitleKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.value(titleKey))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(colorScheme == .dark ? StashyTheme.cream : StashyTheme.charcoal)
            Text(L10n.value(subtitleKey))
                .font(.subheadline)
                .foregroundStyle(colorScheme == .dark ? StashyTheme.cream.opacity(0.72) : StashyTheme.charcoal.opacity(0.72))
        }
        .padding(.horizontal, 4)
    }
}

struct StashyGlassBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) { content }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color
    var body: some View {
        Label(title, systemImage: "circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .symbolRenderingMode(.palette)
            .foregroundStyle(color, color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular.tint(color.opacity(0.2)), in: .capsule)
    }
}
