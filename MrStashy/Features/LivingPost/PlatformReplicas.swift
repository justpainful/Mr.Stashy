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
            // A post's video plays where the post is, at the video's own shape, the way it did
            // on the source. The expand control opens the dedicated player for anyone who wants
            // the whole screen, Picture in Picture, or AirPlay.
            InlineVideoPlayer(
                url: url,
                declaredAspect: declaredAspect,
                cornerRadius: cornerRadius,
                onExpand: onPlay
            )
            .accessibilityIdentifier("livingPost.media.\(record.orderIndex)")
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
struct ReplicaAvatar: View {
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
