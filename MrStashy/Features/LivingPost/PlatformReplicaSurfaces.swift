import SwiftUI

// The per-platform surfaces. Each one fills the width it is given and draws no frame of its own:
// the screen already belongs to the platform, so a card floating in the middle of it — which is
// what these used to be — is the single thing that gives the illusion away.

// MARK: - X / Twitter

/// A saved X post, in the order x.com uses on a single post page: author row, body at reading
/// size, media, timestamp, divider, action row.
struct XPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let skin: PlatformSkin
    let onPlay: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !manifest.text.isEmpty {
                Text(manifest.text)
                    .replicaFont(23)
                    .foregroundStyle(skin.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            if let quote = manifest.quotedPost { quoteBlock(quote).padding(16) }
            mediaBlock.padding(.top, 12)
            Text(manifest.timestampLabel())
                .replicaFont(15, relativeTo: .subheadline)
                .foregroundStyle(skin.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            Divider().overlay(skin.separator).padding(.top, 14)
            ReplicaEngagementBar(
                items: [
                    .init("bubble"), .init("arrow.2.squarepath"),
                    .init("heart"), .init("bookmark"), .init("square.and.arrow.up")
                ],
                skin: skin
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            Divider().overlay(skin.separator)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ReplicaAvatar(author: manifest.author, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(manifest.author.displayName)
                        .replicaFont(16, weight: .bold, relativeTo: .headline)
                        .foregroundStyle(skin.text)
                    if manifest.author.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .replicaFont(14, relativeTo: .footnote)
                            .foregroundStyle(skin.accent)
                            .accessibilityLabel(Text(L10n.value("replica.verified")))
                    }
                }
                if let handle = manifest.author.displayHandle {
                    Text(handle)
                        .replicaFont(15, relativeTo: .subheadline)
                        .foregroundStyle(skin.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "ellipsis")
                .foregroundStyle(skin.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// The arrangements x.com actually draws: one item runs full width, two sit side by side,
    /// three put the first at full height with the other two stacked beside it, four make a 2x2.
    @ViewBuilder private var mediaBlock: some View {
        let media = manifest.orderedMedia
        Group {
            switch media.count {
            case 0:
                EmptyView()
            case 1:
                tile(media[0])
            case 2:
                HStack(spacing: 2) { tile(media[0], square: true); tile(media[1], square: true) }
            case 3:
                HStack(spacing: 2) {
                    tile(media[0], fills: true)
                    VStack(spacing: 2) { tile(media[1], square: true); tile(media[2], square: true) }
                }
                .fixedSize(horizontal: false, vertical: true)
            default:
                VStack(spacing: 2) {
                    HStack(spacing: 2) { tile(media[0], square: true); tile(media[1], square: true) }
                    HStack(spacing: 2) { tile(media[2], square: true); tile(media[3], square: true) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder private func tile(_ media: ArchivedMediaRecord, square: Bool = false, fills: Bool = false) -> some View {
        let item = ReplicaMedia(
            archiveID: archiveID, record: media, cornerRadius: 0,
            mode: fills ? .fill : (square ? .square : .natural),
            totalCount: manifest.orderedMedia.count, onPlay: onPlay
        )
        if fills {
            item.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if square {
            item.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
        } else {
            item
        }
    }

    private func quoteBlock(_ quote: QuotedPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quote.author.displayName)
                .replicaFont(15, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(skin.text)
            Text(quote.text).replicaFont(15, relativeTo: .subheadline).foregroundStyle(skin.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(skin.separator, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - TikTok

/// A saved TikTok on the whole screen, the way TikTok shows one: media behind everything, the
/// account and caption along the bottom, the action rail down the right.
struct TikTokPostReplica: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let manifest: ArchiveManifest
    let archiveID: UUID
    let skin: PlatformSkin
    let onPlay: (URL) -> Void

    private var captionLines: Int { dynamicTypeSize.isAccessibilitySize ? 6 : 3 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            media
            // The caption sits over the picture, so it needs its own contrast rather than
            // relying on whatever happens to be behind it.
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            overlayContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var media: some View {
        if manifest.orderedMedia.count > 1 {
            TabView {
                ForEach(manifest.orderedMedia, id: \.mediaID) { record in
                    ReplicaMedia(
                        archiveID: archiveID, record: record, cornerRadius: 0,
                        mode: .fill, totalCount: manifest.orderedMedia.count, onPlay: onPlay
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
        } else if let record = manifest.orderedMedia.first {
            ReplicaMedia(
                archiveID: archiveID, record: record, cornerRadius: 0,
                mode: .fill, totalCount: 1, onPlay: onPlay
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var overlayContent: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(manifest.author.displayHandle ?? manifest.author.displayName)
                    .replicaFont(17, weight: .bold, relativeTo: .headline)
                if !manifest.text.isEmpty {
                    Text(manifest.text)
                        .replicaFont(15, relativeTo: .subheadline)
                        .lineLimit(captionLines)
                }
                Label(L10n.value("replica.originalSound"), systemImage: "music.note")
                    .replicaFont(14, relativeTo: .footnote)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            Spacer(minLength: 0)
            rail
        }
        .padding(.horizontal, 16)
        // Clear of the archive strip along the bottom.
        .padding(.bottom, 96)
    }

    private var rail: some View {
        VStack(spacing: 22) {
            ReplicaAvatar(author: manifest.author, size: 48)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            ForEach(["heart.fill", "ellipsis.bubble.fill", "bookmark.fill", "arrowshape.turn.up.right.fill"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .replicaFont(28, relativeTo: .title2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.value("replica.actions")))
    }
}

// MARK: - Instagram / Threads

/// A saved Instagram post at full width, in Instagram's own order: header, media, action row,
/// caption, date.
struct InstagramPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let skin: PlatformSkin
    let onPlay: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ReplicaAvatar(author: manifest.author, size: 34)
                Text(manifest.author.username ?? manifest.author.displayName)
                    .replicaFont(15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(skin.text)
                if manifest.author.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .replicaFont(13, relativeTo: .footnote)
                        .foregroundStyle(skin.accent)
                        .accessibilityLabel(Text(L10n.value("replica.verified")))
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis").foregroundStyle(skin.text).accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            media

            HStack(spacing: 18) {
                ReplicaEngagementBar(
                    items: [.init("heart", tint: skin.text), .init("bubble.right", tint: skin.text), .init("paperplane", tint: skin.text)],
                    skin: skin, size: 24, distributed: false
                )
                Image(systemName: "bookmark")
                    .replicaFont(24, relativeTo: .title3)
                    .foregroundStyle(skin.text)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if !manifest.text.isEmpty {
                (Text((manifest.author.username ?? manifest.author.displayName) + "  ").fontWeight(.semibold)
                    + Text(manifest.text))
                    .replicaFont(15, relativeTo: .subheadline)
                    .foregroundStyle(skin.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
            Text(manifest.timestampLabel(dateOnly: true).uppercased())
                .replicaFont(11, relativeTo: .caption2)
                .foregroundStyle(skin.secondary)
                .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var media: some View {
        if manifest.orderedMedia.count > 1 {
            TabView {
                ForEach(manifest.orderedMedia, id: \.mediaID) { record in
                    ReplicaMedia(
                        archiveID: archiveID, record: record, cornerRadius: 0,
                        mode: .fill, totalCount: manifest.orderedMedia.count, onPlay: onPlay
                    )
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .aspectRatio(1, contentMode: .fit)
        } else if let record = manifest.orderedMedia.first {
            ReplicaMedia(archiveID: archiveID, record: record, cornerRadius: 0, totalCount: 1, onPlay: onPlay)
        }
    }
}

// MARK: - Every other source

/// The full-width post page for a source without a bespoke replica. It still wears that
/// platform's canvas, accent, and bar, so a saved Reddit, Bluesky, YouTube, Pinterest, Snapchat,
/// Tumblr, Kick, or Imgur post reads as itself rather than as a neutral archive row.
struct BrandedPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let skin: PlatformSkin
    let onPlay: (URL) -> Void

    /// Reddit's own action row is a vote pair; everywhere else it is a reply/share pair.
    private var actions: [ReplicaEngagementBar.Item] {
        manifest.platform == .reddit
            ? [.init("arrow.up"), .init("arrow.down"), .init("bubble.left"), .init("square.and.arrow.up")]
            : [.init("heart"), .init("bubble.left"), .init("arrow.2.squarepath"), .init("square.and.arrow.up")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ReplicaAvatar(author: manifest.author, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(manifest.author.displayName)
                            .replicaFont(16, weight: .bold, relativeTo: .headline)
                            .foregroundStyle(skin.text)
                        if manifest.author.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .replicaFont(13, relativeTo: .footnote)
                                .foregroundStyle(skin.accent)
                                .accessibilityLabel(Text(L10n.value("replica.verified")))
                        }
                    }
                    Text(manifest.timestampLabel(dateOnly: true))
                        .replicaFont(13, relativeTo: .caption)
                        .foregroundStyle(skin.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis").foregroundStyle(skin.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if !manifest.text.isEmpty {
                Text(manifest.text)
                    .replicaFont(17)
                    .foregroundStyle(skin.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            ForEach(manifest.orderedMedia, id: \.mediaID) { record in
                ReplicaMedia(
                    archiveID: archiveID, record: record, cornerRadius: 0,
                    totalCount: manifest.orderedMedia.count, onPlay: onPlay
                )
                .padding(.bottom, 2)
            }

            Divider().overlay(skin.separator).padding(.top, 10)
            ReplicaEngagementBar(items: actions, skin: skin)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            Divider().overlay(skin.separator)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
