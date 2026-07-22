import SwiftUI

enum StashyTheme {
    static let cream = Color(red: 0.98, green: 0.95, blue: 0.87)
    static let charcoal = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let lavender = Color(red: 0.61, green: 0.51, blue: 0.88)
    static let butter = Color(red: 0.98, green: 0.80, blue: 0.32)
    static let pink = Color(red: 0.92, green: 0.44, blue: 0.61)
    static let aqua = Color(red: 0.52, green: 0.80, blue: 0.79)
    static let green = Color(red: 0.18, green: 0.42, blue: 0.30)
    static let darkSurface = Color(red: 0.12, green: 0.13, blue: 0.13)
    static let surface = Color(uiColor: .secondarySystemBackground)
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
