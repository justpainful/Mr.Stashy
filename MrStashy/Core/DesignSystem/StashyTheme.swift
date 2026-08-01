import SwiftUI

enum StashyTheme {
    // A cleaner, less orange warm-white so the pastel surfaces read as modern rather than dated.
    static let cream = Color(red: 0.98, green: 0.98, blue: 0.97)
    static let charcoal = Color(red: 0.13, green: 0.11, blue: 0.17)
    // Deeper, more saturated violet/indigo accents. They carry white button text at a higher
    // contrast and give the interface a more deliberate, less washed-out feel.
    static let lavender = Color(red: 0.40, green: 0.30, blue: 0.92)
    static let butter = Color(red: 1.00, green: 0.72, blue: 0.26)
    static let pink = Color(red: 0.95, green: 0.30, blue: 0.44)
    static let aqua = Color(red: 0.24, green: 0.72, blue: 0.82)
    // Kept as the semantic success/action token for compatibility; it is indigo, not green.
    static let green = Color(red: 0.34, green: 0.25, blue: 0.86)
    static let darkSurface = Color(red: 0.09, green: 0.09, blue: 0.13)
    static let surface = Color(uiColor: .secondarySystemBackground)

    /// Primary text. Fixed charcoal disappears on the dark background, so the token resolves
    /// per appearance instead of per call site.
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.97, blue: 0.94, alpha: 1)
            : UIColor(red: 0.14, green: 0.12, blue: 0.18, alpha: 1)
    })

    /// Secondary text, kept above the 4.5:1 contrast ratio in both appearances.
    static let inkSecondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.97, blue: 0.94, alpha: 0.74)
            : UIColor(red: 0.14, green: 0.12, blue: 0.18, alpha: 0.70)
    })

    /// Container borders and field outlines.
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.22)
            : UIColor(red: 0.14, green: 0.12, blue: 0.18, alpha: 0.18)
    })

    static func accent(for theme: UserSettings.Theme) -> Color {
        switch theme {
        case .studio: lavender
        case .citrus: Color(red: 0.84, green: 0.20, blue: 0.18)
        case .ember: Color(red: 0.80, green: 0.16, blue: 0.31)
        case .ocean: Color(red: 0.10, green: 0.43, blue: 0.72)
        }
    }

    /// Each theme tints the whole canvas — in dark mode too, so the four dark themes are
    /// genuinely different backgrounds rather than the same near-black. Text tokens resolve by
    /// light/dark independently, so they stay legible on every tint.
    static func background(for theme: UserSettings.Theme, colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            switch theme {
            case .studio: return Color(red: 0.07, green: 0.07, blue: 0.11)
            case .citrus: return Color(red: 0.13, green: 0.07, blue: 0.02)
            case .ember: return Color(red: 0.13, green: 0.04, blue: 0.09)
            case .ocean: return Color(red: 0.03, green: 0.08, blue: 0.15)
            }
        }
        switch theme {
        case .studio: return cream
        case .citrus: return Color(red: 1.00, green: 0.92, blue: 0.60)
        case .ember: return Color(red: 1.00, green: 0.86, blue: 0.82)
        case .ocean: return Color(red: 0.80, green: 0.91, blue: 0.98)
        }
    }

    /// A card/surface colour that also follows the theme, so surfaces feel part of the same
    /// palette instead of a flat system grey on top of a tinted background.
    static func cardSurface(for theme: UserSettings.Theme, colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            switch theme {
            case .studio: return Color(red: 0.13, green: 0.13, blue: 0.18)
            case .citrus: return Color(red: 0.20, green: 0.13, blue: 0.06)
            case .ember: return Color(red: 0.20, green: 0.10, blue: 0.15)
            case .ocean: return Color(red: 0.07, green: 0.14, blue: 0.22)
            }
        }
        return Color.white
    }

    /// A status colour that stays legible on both backgrounds.
    static func color(for status: SupportStatus) -> Color {
        switch status {
        case .passing: Color(red: 0.16, green: 0.60, blue: 0.36)
        case .limited: Color(red: 0.78, green: 0.52, blue: 0.05)
        case .needsCredential: Color(red: 0.10, green: 0.43, blue: 0.72)
        case .failing, .blocked: pink
        case .notShipped: Color.secondary
        }
    }
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
    /// The sources the Catch screen offers. It is derived from the capability registry so the
    /// picker can never advertise a source the app has no working adapter for, and never hides
    /// one that works.
    static var quickCapturePlatforms: [Platform] {
        PlatformCapabilityRegistry.usable.map(\.platform)
    }

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
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        StashyTheme.background(for: appState.settings.theme, colorScheme: colorScheme)
            .ignoresSafeArea()
    }
}

struct FeatureHeader: View {
    let titleKey: String
    let subtitleKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.value(titleKey))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(StashyTheme.ink)
            Text(L10n.value(subtitleKey))
                .font(.subheadline)
                .foregroundStyle(StashyTheme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct StashyGlassBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            // Buttons wrap instead of truncating, which is what happens to three actions on a
            // narrow phone or at a large Dynamic Type size.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { content }
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
        }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
                // The label text has to stay readable; tinting it with the status colour is
                // what made these pills unreadable against their own background.
                .foregroundStyle(StashyTheme.ink)
        } icon: {
            Image(systemName: "circle.fill").foregroundStyle(color)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(color.opacity(0.2)), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
