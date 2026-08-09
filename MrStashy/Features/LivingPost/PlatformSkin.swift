import SwiftUI

/// How one platform's own app looks, so a saved post can be shown on that platform's terms
/// rather than as a card sitting on Stashy's background.
///
/// A replica that fills only the middle of the screen never reads as the source — the giveaway
/// is the frame around it. These values let the whole surface belong to the platform: its
/// canvas, its bar, its separators, its idea of light or dark.
struct PlatformSkin {
    /// The canvas the whole screen adopts.
    var background: Color
    /// Cards and rows drawn on that canvas.
    var surface: Color
    var text: Color
    var secondary: Color
    var accent: Color
    var separator: Color
    var scheme: ColorScheme
    /// What the platform's own top bar says above a single post.
    var barTitleKey: String
    /// True where the platform runs media edge to edge under translucent chrome, the way TikTok
    /// and Reels do. Those get floating controls instead of a solid bar.
    var isImmersive: Bool = false

    static func skin(for platform: Platform) -> PlatformSkin {
        switch platform {
        case .x:
            return PlatformSkin(
                background: .black,
                surface: .black,
                text: .white,
                secondary: Color(red: 0.44, green: 0.48, blue: 0.52),
                accent: Color(red: 0.114, green: 0.631, blue: 0.949),
                separator: Color(red: 0.18, green: 0.19, blue: 0.20),
                scheme: .dark,
                barTitleKey: "replica.bar.post"
            )
        case .instagram, .threads:
            return PlatformSkin(
                background: .white,
                surface: .white,
                text: Color(red: 0.09, green: 0.09, blue: 0.10),
                secondary: Color(red: 0.46, green: 0.46, blue: 0.49),
                accent: Color(red: 0.13, green: 0.52, blue: 0.96),
                separator: Color(red: 0.90, green: 0.90, blue: 0.92),
                scheme: .light,
                barTitleKey: platform == .threads ? "replica.bar.thread" : "replica.bar.post"
            )
        case .tikTok:
            return PlatformSkin(
                background: .black, surface: .black, text: .white,
                secondary: Color(white: 0.72),
                accent: Color(red: 0.98, green: 0.16, blue: 0.35),
                separator: Color(white: 0.18),
                scheme: .dark,
                barTitleKey: "replica.bar.video",
                isImmersive: true
            )
        case .reddit:
            return PlatformSkin(
                background: Color(red: 0.05, green: 0.05, blue: 0.06),
                surface: Color(red: 0.10, green: 0.10, blue: 0.11),
                text: .white,
                secondary: Color(red: 0.65, green: 0.66, blue: 0.67),
                accent: Color(red: 1.00, green: 0.35, blue: 0.13),
                separator: Color(white: 0.18),
                scheme: .dark,
                barTitleKey: "replica.bar.post"
            )
        case .bluesky:
            return PlatformSkin(
                background: .white, surface: .white,
                text: Color(red: 0.06, green: 0.09, blue: 0.13),
                secondary: Color(red: 0.42, green: 0.46, blue: 0.52),
                accent: Color(red: 0.00, green: 0.44, blue: 0.90),
                separator: Color(red: 0.89, green: 0.91, blue: 0.94),
                scheme: .light,
                barTitleKey: "replica.bar.post"
            )
        case .youTube:
            return PlatformSkin(
                background: Color(red: 0.06, green: 0.06, blue: 0.06),
                surface: Color(red: 0.11, green: 0.11, blue: 0.11),
                text: .white,
                secondary: Color(red: 0.67, green: 0.67, blue: 0.68),
                accent: Color(red: 1.00, green: 0.00, blue: 0.00),
                separator: Color(white: 0.17),
                scheme: .dark,
                barTitleKey: "replica.bar.video"
            )
        case .pinterest:
            return PlatformSkin(
                background: .white, surface: .white,
                text: Color(red: 0.07, green: 0.07, blue: 0.07),
                secondary: Color(red: 0.46, green: 0.46, blue: 0.49),
                accent: Color(red: 0.90, green: 0.00, blue: 0.12),
                separator: Color(red: 0.90, green: 0.90, blue: 0.92),
                scheme: .light,
                barTitleKey: "replica.bar.pin"
            )
        case .snapchat:
            return PlatformSkin(
                background: Color(red: 1.00, green: 0.988, blue: 0.00),
                surface: .white,
                text: .black,
                secondary: Color(red: 0.25, green: 0.25, blue: 0.20),
                accent: .black,
                separator: Color(red: 0.85, green: 0.84, blue: 0.30),
                scheme: .light,
                barTitleKey: "replica.bar.story"
            )
        case .tumblr:
            return PlatformSkin(
                background: Color(red: 0.00, green: 0.11, blue: 0.24),
                surface: Color(red: 0.04, green: 0.15, blue: 0.29),
                text: .white,
                secondary: Color(red: 0.62, green: 0.70, blue: 0.80),
                accent: Color(red: 0.34, green: 0.53, blue: 0.75),
                separator: Color(red: 0.10, green: 0.22, blue: 0.36),
                scheme: .dark,
                barTitleKey: "replica.bar.post"
            )
        case .kick:
            return PlatformSkin(
                background: Color(red: 0.05, green: 0.05, blue: 0.06),
                surface: Color(red: 0.09, green: 0.10, blue: 0.09),
                text: .white,
                secondary: Color(red: 0.62, green: 0.64, blue: 0.62),
                accent: Color(red: 0.33, green: 0.99, blue: 0.10),
                separator: Color(white: 0.16),
                scheme: .dark,
                barTitleKey: "replica.bar.clip"
            )
        case .imgur:
            return PlatformSkin(
                background: Color(red: 0.11, green: 0.11, blue: 0.12),
                surface: Color(red: 0.15, green: 0.15, blue: 0.16),
                text: .white,
                secondary: Color(red: 0.62, green: 0.63, blue: 0.64),
                accent: Color(red: 0.11, green: 0.72, blue: 0.43),
                separator: Color(white: 0.20),
                scheme: .dark,
                barTitleKey: "replica.bar.post"
            )
        case .discord, .directMedia:
            return PlatformSkin(
                background: Color(red: 0.12, green: 0.12, blue: 0.14),
                surface: Color(red: 0.17, green: 0.17, blue: 0.20),
                text: .white,
                secondary: Color(red: 0.66, green: 0.66, blue: 0.69),
                accent: platform.sourceStyle.accent,
                separator: Color(white: 0.22),
                scheme: .dark,
                barTitleKey: "replica.bar.post"
            )
        }
    }
}

/// A count rendered the way a social app renders it: 12.4K, 3.1M.
enum EngagementCount {
    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(L10n.activeLocale))
    }
}

/// The engagement row every platform draws under a post.
///
/// Stashy never invents numbers. The glyphs are the source's chrome reproduced so the page looks
/// like itself; without counts beside them they are plainly decoration rather than a claim about
/// how the post performed.
struct ReplicaEngagementBar: View {
    struct Item {
        let symbol: String
        let tint: Color?

        init(_ symbol: String, tint: Color? = nil) {
            self.symbol = symbol
            self.tint = tint
        }
    }

    let items: [Item]
    let skin: PlatformSkin
    var size: CGFloat = 20
    var distributed = true

    var body: some View {
        HStack(spacing: distributed ? 0 : 22) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Image(systemName: item.symbol)
                    .replicaFont(size, relativeTo: .body)
                    .foregroundStyle(item.tint ?? skin.secondary)
                if distributed, index < items.count - 1 { Spacer(minLength: 0) }
            }
            if !distributed { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.value("replica.actions")))
    }
}
