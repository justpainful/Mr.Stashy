import AVKit
import SwiftUI

// A saved post is shown the way it looked on its own platform — an X post reads like x.com, a
// TikTok like TikTok, an Instagram post like Instagram — so the archive feels like the post was
// kept, not merely downloaded as loose files. Each replica renders from the archive manifest and
// the media already on the device.
//
// Looking like the source is not a licence to be unreadable. Every point size here is scaled for
// Dynamic Type, every decorative glyph is hidden from VoiceOver, every real control is labelled,
// and every palette clears the 4.5:1 contrast ratio for the text it carries.

/// A URL wrapped for `fullScreenCover(item:)`, which needs an Identifiable value.
struct PlayerItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

extension ResolvedAuthor {
    /// A verification tick is only ever shown when the source actually reported the account as
    /// verified — never by default.
    var isVerified: Bool {
        badges.contains { badge in
            let value = badge.lowercased()
            return value.contains("verified") || value.contains("check") || value == "blue"
        }
    }

    /// The handle, wrapped so it keeps its own direction inside an Arabic card. Without the
    /// isolate, "@stashy" next to Arabic text has its "@" thrown to the wrong end.
    var displayHandle: String? {
        guard let username, !username.isEmpty else { return nil }
        return L10n.isolated("@\(username)")
    }
}

extension ArchiveManifest {
    /// The date line a replica shows.
    ///
    /// A replica is convincing by design, which makes a wrong date in it maximally believable.
    /// Falling back to the day the archive was written meant a 2019 post appeared, inside a
    /// pixel-faithful card, as though it had been posted today. When the source published no
    /// date, the card says which date it is showing instead of quietly substituting one.
    func timestampLabel(dateOnly: Bool = false) -> String {
        let time: Date.FormatStyle.TimeStyle = dateOnly ? .omitted : .shortened
        if let timestamp { return L10n.date(timestamp, time: time) }
        return L10n.format("livingPost.savedOn", L10n.date(savedAt, time: time))
    }
}

// MARK: - Shared media inside a replica

enum ReplicaMediaMode {
    /// Photos and GIFs at full fidelity; a video shows its poster at its own aspect ratio.
    case natural
    /// A square tile for multi-image grids.
    case square
    /// Fills whatever bounded space the parent gives it (the TikTok canvas).
    case fill
}

/// One media item inside a replica: photos and GIFs render inline, audio plays in place, and a
/// video shows its poster with a play button and opens the dedicated player when tapped. A long
/// press peeks it larger and offers to save or share.
struct ReplicaMedia: View {
    @Environment(AppState.self) private var appState
    let archiveID: UUID
    let record: ArchivedMediaRecord
    var cornerRadius: CGFloat = 14
    var mode: ReplicaMediaMode = .natural
    /// How many items the post holds, so each one can say which of them it is.
    var totalCount: Int = 1
    let onPlay: (URL) -> Void
    @State private var localURL: URL?
    @State private var savedToPhotos = false

    var body: some View {
        content
            .task(id: record.localFilename) {
                guard let filename = record.localFilename else { return }
                localURL = await appState.archiveStore.localMediaURL(archiveID: archiveID, filename: filename)
            }
            .contextMenu {
                if let localURL {
                    if record.type != .audio {
                        Button {
                            Task { await save(localURL) }
                        } label: {
                            Label(
                                L10n.value(savedToPhotos ? "livingPost.savedToPhotos" : "livingPost.saveToPhotos"),
                                systemImage: savedToPhotos ? "checkmark" : "photo.badge.arrow.down"
                            )
                        }
                    }
                    ShareLink(item: localURL) {
                        Label(L10n.value("livingPost.shareMedia"), systemImage: "square.and.arrow.up")
                    }
                }
            } preview: {
                if let localURL {
                    // A context-menu preview is a picture, not a control: iOS renders it without
                    // touch handling, so a player here would draw buttons that do nothing.
                    ArchivedMediaPreview(
                        url: localURL,
                        type: record.type,
                        declaredAspect: declaredAspect,
                        accessibilityText: record.altText,
                        duration: record.durationSeconds,
                        isInteractive: false
                    )
                    .frame(width: 360)
                    .padding(8)
                }
            }
    }

    /// The name every item in this post shares, so a four-image post is four distinguishable
    /// elements rather than four identical "button"s.
    private var itemName: Text {
        Text(L10n.format(
            "media.item.accessibility",
            record.type.shortLabel,
            Int64(record.orderIndex + 1),
            Int64(max(totalCount, record.orderIndex + 1))
        ))
    }

    private var declaredAspect: CGFloat? {
        guard let width = record.variant?.width, let height = record.variant?.height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }

    @ViewBuilder private var content: some View {
        if let localURL, record.type == .audio {
            // Audio has nothing to show. In a grid or a full-bleed canvas it drew a mute tile
            // with a waveform glyph and no way to hear it; the player belongs here whatever
            // shape the surrounding replica wants.
            AudioPlaybackView(url: localURL, title: record.altText)
        } else if let localURL {
            switch mode {
            case .natural:
                naturalContent(localURL)
            case .square:
                tappable(localURL) {
                    LocalMediaThumbnail(url: localURL, type: record.type, cornerRadius: cornerRadius, duration: record.durationSeconds)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                }
            case .fill:
                tappable(localURL) {
                    LocalMediaThumbnail(url: localURL, type: record.type, cornerRadius: cornerRadius, duration: record.durationSeconds)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.gray.opacity(0.15))
                .frame(height: 220)
                .overlay { ProgressView() }
                .accessibilityLabel(Text(L10n.value("livingPost.loading")))
        }
    }

    @ViewBuilder private func naturalContent(_ url: URL) -> some View {
        switch record.type {
        case .video:
            tappable(url) {
                LocalMediaThumbnail(url: url, type: .video, cornerRadius: cornerRadius, duration: record.durationSeconds)
                    .aspectRatio(VideoGeometry.clamped(declaredAspect), contentMode: .fit)
            }
        case .photo, .gif:
            ArchivedMediaPreview(
                url: url,
                type: record.type,
                declaredAspect: declaredAspect,
                accessibilityText: record.altText
            )
        case .audio:
            // Saved audio plays here. Handing the file to another app to hear what Stashy saved
            // was the one media kind the archive could not actually show you.
            AudioPlaybackView(url: url, title: record.altText)
        }
    }

    /// A video is tappable to open the player; a still just displays. Both are named, because an
    /// unlabelled image button is indistinguishable from every other one in the same post.
    @ViewBuilder private func tappable<Label: View>(_ url: URL, @ViewBuilder _ label: () -> Label) -> some View {
        if record.type == .video {
            Button { onPlay(url) } label: { label() }
                .buttonStyle(.plain)
                .accessibilityLabel(itemName)
                .accessibilityHint(Text(L10n.value("media.playback.hint")))
                .accessibilityAddTraits(.startsMediaSession)
                .accessibilityIdentifier("livingPost.media.\(record.orderIndex)")
        } else {
            label()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(record.altText.map(Text.init) ?? itemName)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("livingPost.media.\(record.orderIndex)")
        }
    }

    private func save(_ url: URL) async {
        do {
            try await PhotoLibrarySaver.save(url: url, type: record.type)
            savedToPhotos = true
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
    }
}

/// The author's picture. It is decoration: the name it sits beside is the information, and an
/// unlabelled image in a header only adds a stop VoiceOver has nothing to say about.
private struct ReplicaAvatar: View {
    let author: ResolvedAuthor
    var size: CGFloat = 44
    var body: some View {
        Group {
            if let url = author.avatarURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.gray.opacity(0.25))
                }
            } else {
                Circle().fill(Color.gray.opacity(0.25))
                    .overlay { Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let name = author.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "?" : String(name.prefix(1)).uppercased()
    }
}

/// The row of reply/repost/like/share glyphs every replica draws to look like its source. They
/// are a picture of the original post's chrome, not working controls, so they are one silent
/// element with an honest description rather than four unlabelled buttons.
private struct ReplicaActionRow: View {
    let symbols: [String]
    let color: Color
    var size: CGFloat = 16
    /// `nil` spreads the glyphs across the full width, the way a post's action bar sits.
    var spacing: CGFloat?
    var axis: Axis = .horizontal

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: spacing ?? 16) { glyphs }
            } else if spacing == nil {
                HStack {
                    ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                        glyph(symbol)
                        if index < symbols.count - 1 { Spacer() }
                    }
                }
            } else {
                HStack(spacing: spacing) { glyphs }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.value("replica.actions")))
    }

    private var glyphs: some View {
        ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in glyph(symbol) }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .replicaFont(size, relativeTo: .footnote)
            .foregroundStyle(color)
    }
}

// MARK: - X / Twitter

struct XPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let onPlay: (URL) -> Void

    // x.com's dark ("lights out") palette: a true-black card, white text, muted grey handle.
    private enum Palette {
        static let card = Color.black
        static let text = Color.white
        static let secondary = Color(red: 0.44, green: 0.48, blue: 0.52)
        static let blue = Color(red: 0.114, green: 0.631, blue: 0.949)
        static let border = Color(red: 0.18, green: 0.19, blue: 0.20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ReplicaAvatar(author: manifest.author, size: 48)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(manifest.author.displayName).replicaFont(15, weight: .bold, relativeTo: .subheadline).foregroundStyle(Palette.text)
                        if manifest.author.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .replicaFont(13, relativeTo: .caption)
                                .foregroundStyle(Palette.blue)
                                .accessibilityLabel(Text(L10n.value("replica.verified")))
                        }
                    }
                    if let handle = manifest.author.displayHandle {
                        Text(handle).replicaFont(15, relativeTo: .subheadline).foregroundStyle(Palette.secondary)
                    }
                }
                Spacer()
                Text(verbatim: "𝕏")
                    .replicaFont(22, weight: .black, relativeTo: .title3)
                    .foregroundStyle(Palette.text)
                    .accessibilityHidden(true)
            }
            if !manifest.text.isEmpty {
                Text(manifest.text)
                    .replicaFont(17)
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quote = manifest.quotedPost { quoteBlock(quote) }
            mediaBlock
            Text(manifest.timestampLabel())
                .replicaFont(14, relativeTo: .footnote)
                .foregroundStyle(Palette.secondary)
            Divider().overlay(Palette.border)
            ReplicaActionRow(symbols: ["bubble.left", "arrow.2.squarepath", "heart", "square.and.arrow.up"], color: Palette.secondary)
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.border, lineWidth: 1) }
        .environment(\.colorScheme, .dark)
    }

    /// x.com's own arrangements: one item fills the card, two sit side by side, three put the
    /// first tall on one side with the other two stacked beside it, and four make a 2×2. A plain
    /// two-column grid left a three-image post with an empty black quarter, which is the one
    /// shape x.com never draws.
    @ViewBuilder private var mediaBlock: some View {
        let media = manifest.orderedMedia
        Group {
            switch media.count {
            case 0:
                EmptyView()
            case 1:
                tile(media[0], corner: 16)
            case 2:
                HStack(spacing: 3) {
                    tile(media[0], square: true)
                    tile(media[1], square: true)
                }
            case 3:
                HStack(spacing: 3) {
                    tile(media[0], square: true)
                    VStack(spacing: 3) {
                        tile(media[1], square: true)
                        tile(media[2], square: true)
                    }
                }
            default:
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        tile(media[0], square: true)
                        tile(media[1], square: true)
                    }
                    HStack(spacing: 3) {
                        tile(media[2], square: true)
                        tile(media[3], square: true)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if !media.isEmpty {
                RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.border, lineWidth: 1)
            }
        }
    }

    @ViewBuilder private func tile(_ media: ArchivedMediaRecord, corner: CGFloat = 0, square: Bool = false) -> some View {
        let item = ReplicaMedia(
            archiveID: archiveID, record: media, cornerRadius: corner,
            mode: square ? .square : .natural, totalCount: manifest.orderedMedia.count, onPlay: onPlay
        )
        if square {
            // `.fit`, not `.fill`: filling asks the tile to cover its slot, which lets it grow
            // past the row and paint over the one beneath it.
            item.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
        } else {
            item
        }
    }

    private func quoteBlock(_ quote: QuotedPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quote.author.displayName).replicaFont(14, weight: .semibold, relativeTo: .footnote).foregroundStyle(Palette.text)
            Text(quote.text).replicaFont(14, relativeTo: .footnote).foregroundStyle(Palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.border, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - TikTok

struct TikTokPostReplica: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let manifest: ArchiveManifest
    let archiveID: UUID
    let onPlay: (URL) -> Void

    // The canvas grows with the text-size setting. A fixed 560pt frame clipped the caption and
    // the account name outright at the accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var canvasHeight: CGFloat = 560

    private var captionLines: Int { dynamicTypeSize.isAccessibilitySize ? 8 : 3 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if manifest.orderedMedia.count > 1 {
                TabView {
                    ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                        ReplicaMedia(
                            archiveID: archiveID, record: media, cornerRadius: 0,
                            mode: .fill, totalCount: manifest.orderedMedia.count, onPlay: onPlay
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            } else if let media = manifest.orderedMedia.first {
                ReplicaMedia(
                    archiveID: archiveID, record: media, cornerRadius: 0,
                    mode: .fill, totalCount: 1, onPlay: onPlay
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(manifest.author.displayHandle ?? manifest.author.displayName)
                        .replicaFont(16, weight: .bold, relativeTo: .subheadline)
                    if !manifest.text.isEmpty {
                        Text(manifest.text).replicaFont(14, relativeTo: .footnote).lineLimit(captionLines)
                    }
                    Label(L10n.value("replica.originalSound"), systemImage: "music.note")
                        .replicaFont(13, relativeTo: .caption)
                }
                .foregroundStyle(.white)
                .shadow(radius: 3)
                Spacer()
                VStack(spacing: 20) {
                    ReplicaAvatar(author: manifest.author, size: 46).overlay(Circle().stroke(.white, lineWidth: 2))
                    ReplicaActionRow(
                        symbols: ["heart.fill", "ellipsis.bubble.fill", "bookmark.fill", "arrowshape.turn.up.right.fill"],
                        color: .white, size: 26, spacing: 20, axis: .vertical
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(16)
        }
        .frame(height: min(canvasHeight, 900))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Instagram / Threads

struct InstagramPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let onPlay: (URL) -> Void

    private enum Palette {
        static let card = Color.white
        static let text = Color(red: 0.09, green: 0.09, blue: 0.10)
        // 4.55:1 on white. The lighter grey Instagram itself uses is 3.3:1, which is below the
        // floor for the 11pt timestamp that is often a saved post's only provenance.
        static let secondary = Color(red: 0.46, green: 0.46, blue: 0.49)
        static let border = Color(red: 0.90, green: 0.90, blue: 0.92)
        static let verified = Color(red: 0.13, green: 0.52, blue: 0.96)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ReplicaAvatar(author: manifest.author, size: 36)
                Text(manifest.author.username ?? manifest.author.displayName)
                    .replicaFont(14, weight: .semibold, relativeTo: .footnote).foregroundStyle(Palette.text)
                if manifest.author.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .replicaFont(12, relativeTo: .caption2)
                        .foregroundStyle(Palette.verified)
                        .accessibilityLabel(Text(L10n.value("replica.verified")))
                }
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(Palette.text).accessibilityHidden(true)
            }
            .padding(12)
            if manifest.orderedMedia.count > 1 {
                TabView {
                    ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                        ReplicaMedia(
                            archiveID: archiveID, record: media, cornerRadius: 0,
                            mode: .fill, totalCount: manifest.orderedMedia.count, onPlay: onPlay
                        )
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .aspectRatio(1, contentMode: .fit)
            } else if let media = manifest.orderedMedia.first {
                ReplicaMedia(archiveID: archiveID, record: media, cornerRadius: 0, totalCount: 1, onPlay: onPlay)
            }
            ReplicaActionRow(
                symbols: ["heart", "bubble.right", "paperplane", "bookmark"],
                color: Palette.text, size: 22, spacing: 16
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if !manifest.text.isEmpty {
                (Text((manifest.author.username ?? manifest.author.displayName) + "  ").fontWeight(.semibold)
                    + Text(manifest.text))
                    .replicaFont(14, relativeTo: .footnote)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
            Text(manifest.timestampLabel(dateOnly: true).uppercased())
                .replicaFont(11, relativeTo: .caption2)
                .foregroundStyle(Palette.secondary)
                .padding(12)
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.border, lineWidth: 1) }
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Generic (every other source)

struct GenericPostReplica: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let manifest: ArchiveManifest
    let archiveID: UUID
    let onPlay: (URL) -> Void

    private var accent: Color { manifest.platform.sourceStyle.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ReplicaAvatar(author: manifest.author, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.author.displayName).font(.headline).foregroundStyle(StashyTheme.ink)
                    HStack(spacing: 5) {
                        PlatformIcon(platform: manifest.platform, size: 16, isDecorative: true)
                        Text(L10n.value(manifest.platform.titleKey))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StashyTheme.inkSecondary)
                }
                Spacer()
                Text(manifest.timestampLabel(dateOnly: true))
                    .font(.caption).foregroundStyle(StashyTheme.inkSecondary)
            }
            if !manifest.text.isEmpty {
                Text(manifest.text).font(.body).foregroundStyle(StashyTheme.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                ReplicaMedia(
                    archiveID: archiveID, record: media, cornerRadius: 16,
                    totalCount: manifest.orderedMedia.count, onPlay: onPlay
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(16)
        .background(StashyTheme.cardSurface(for: appState.settings.theme, colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.28), lineWidth: 1) }
    }
}

// MARK: - Branded replicas for the remaining platforms

/// The signature colours of one platform, so its saved post wears that platform's skin. Every
/// `secondary` value here clears 4.5:1 against its own background — a replica that is faithful
/// but unreadable has failed at the only job it has.
struct BrandKit {
    let background: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let dark: Bool
}

enum PlatformBrand {
    static func kit(for platform: Platform) -> BrandKit {
        switch platform {
        case .youTube:
            return BrandKit(background: Color(red: 0.09, green: 0.09, blue: 0.09), text: .white, secondary: Color(red: 0.67, green: 0.67, blue: 0.68), accent: Color(red: 1.00, green: 0.00, blue: 0.00), dark: true)
        case .pinterest:
            return BrandKit(background: .white, text: Color(red: 0.07, green: 0.07, blue: 0.07), secondary: Color(red: 0.46, green: 0.46, blue: 0.49), accent: Color(red: 0.90, green: 0.00, blue: 0.12), dark: false)
        case .snapchat:
            return BrandKit(background: Color(red: 1.00, green: 0.988, blue: 0.00), text: .black, secondary: Color(red: 0.25, green: 0.25, blue: 0.20), accent: .black, dark: false)
        case .tumblr:
            return BrandKit(background: Color(red: 0.00, green: 0.11, blue: 0.24), text: .white, secondary: Color(red: 0.62, green: 0.70, blue: 0.80), accent: Color(red: 0.34, green: 0.53, blue: 0.75), dark: true)
        case .kick:
            return BrandKit(background: Color(red: 0.05, green: 0.05, blue: 0.06), text: .white, secondary: Color(red: 0.62, green: 0.64, blue: 0.62), accent: Color(red: 0.33, green: 0.99, blue: 0.10), dark: true)
        case .imgur:
            return BrandKit(background: Color(red: 0.11, green: 0.11, blue: 0.12), text: .white, secondary: Color(red: 0.62, green: 0.63, blue: 0.64), accent: Color(red: 0.11, green: 0.72, blue: 0.43), dark: true)
        case .reddit:
            return BrandKit(background: Color(red: 0.05, green: 0.05, blue: 0.06), text: .white, secondary: Color(red: 0.65, green: 0.66, blue: 0.67), accent: Color(red: 1.00, green: 0.35, blue: 0.13), dark: true)
        case .bluesky:
            return BrandKit(background: .white, text: Color(red: 0.06, green: 0.09, blue: 0.13), secondary: Color(red: 0.42, green: 0.46, blue: 0.52), accent: Color(red: 0.00, green: 0.44, blue: 0.90), dark: false)
        default:
            return BrandKit(background: Color(red: 0.12, green: 0.12, blue: 0.14), text: .white, secondary: Color(red: 0.62, green: 0.62, blue: 0.64), accent: platform.sourceStyle.accent, dark: true)
        }
    }
}

/// A faithful-enough branded card for platforms without a bespoke replica: it wears the
/// platform's colours and logo so a saved YouTube, Pinterest, Snapchat, Tumblr, Kick, Imgur,
/// Reddit, or Bluesky post still reads as itself rather than as a neutral archive row.
struct BrandedPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let onPlay: (URL) -> Void

    private var brand: BrandKit { PlatformBrand.kit(for: manifest.platform) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ReplicaAvatar(author: manifest.author, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(manifest.author.displayName).replicaFont(15, weight: .bold, relativeTo: .subheadline).foregroundStyle(brand.text)
                        if manifest.author.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .replicaFont(12, relativeTo: .caption2)
                                .foregroundStyle(brand.accent)
                                .accessibilityLabel(Text(L10n.value("replica.verified")))
                        }
                    }
                    if let handle = manifest.author.displayHandle {
                        Text(handle).replicaFont(14, relativeTo: .footnote).foregroundStyle(brand.secondary)
                    }
                }
                Spacer()
                PlatformIcon(platform: manifest.platform, size: 26)
            }
            if !manifest.text.isEmpty {
                Text(manifest.text).replicaFont(16).foregroundStyle(brand.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                ReplicaMedia(
                    archiveID: archiveID, record: media, cornerRadius: 14,
                    totalCount: manifest.orderedMedia.count, onPlay: onPlay
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Text(manifest.timestampLabel())
                .replicaFont(13, relativeTo: .caption).foregroundStyle(brand.secondary)
        }
        .padding(16)
        .background(brand.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(brand.accent.opacity(0.35), lineWidth: 1) }
        .environment(\.colorScheme, brand.dark ? .dark : .light)
    }
}
