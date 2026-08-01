import AVKit
import SwiftUI

// A saved post is shown the way it looked on its own platform — an X post reads like x.com, a
// TikTok like TikTok, an Instagram post like Instagram — so the archive feels like the post was
// kept, not merely downloaded as loose files. Each replica renders from the archive manifest and
// the media already on the device.

/// A URL wrapped for `fullScreenCover(item:)`, which needs an Identifiable value.
struct PlayerItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

// MARK: - Full-screen player

/// The dedicated player a video opens into when tapped: black, full-bleed, with native controls.
struct FullScreenVideoPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(16)
            .accessibilityLabel(Text(L10n.value("action.done")))
        }
        .task {
            let created = AVPlayer(url: url)
            player = created
            created.play()
        }
        .onDisappear { player?.pause() }
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

/// One media item inside a replica: photos and GIFs render inline; a video shows its poster with
/// a play button and opens the dedicated player when tapped. A long press peeks it larger and
/// offers to save or share.
struct ReplicaMedia: View {
    @Environment(AppState.self) private var appState
    let archiveID: UUID
    let record: ArchivedMediaRecord
    var cornerRadius: CGFloat = 14
    var mode: ReplicaMediaMode = .natural
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
                    ArchivedMediaPreview(url: localURL, type: record.type)
                        .frame(width: 360)
                        .padding(8)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let localURL {
            switch mode {
            case .natural:
                naturalContent(localURL)
            case .square:
                tappable(localURL) {
                    LocalMediaThumbnail(url: localURL, type: record.type, cornerRadius: cornerRadius)
                        .aspectRatio(1, contentMode: .fit)
                }
            case .fill:
                tappable(localURL) {
                    LocalMediaThumbnail(url: localURL, type: record.type, cornerRadius: cornerRadius)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.gray.opacity(0.15))
                .frame(height: 220)
                .overlay { ProgressView() }
        }
    }

    @ViewBuilder private func naturalContent(_ url: URL) -> some View {
        switch record.type {
        case .video:
            tappable(url) {
                LocalMediaThumbnail(url: url, type: .video, cornerRadius: cornerRadius)
                    .aspectRatio(videoAspect, contentMode: .fit)
            }
        case .photo, .gif:
            ArchivedMediaPreview(url: url, type: record.type)
        case .audio:
            Link(destination: url) {
                Label(L10n.value("livingPost.openMedia"), systemImage: "waveform")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
    }

    /// A video is tappable to open the player; a still just displays.
    @ViewBuilder private func tappable<Label: View>(_ url: URL, @ViewBuilder _ label: () -> Label) -> some View {
        if record.type == .video {
            Button { onPlay(url) } label: { label() }
                .buttonStyle(.plain)
        } else {
            label()
        }
    }

    private var videoAspect: CGFloat {
        if let width = record.variant?.width, let height = record.variant?.height, width > 0, height > 0 {
            return min(max(CGFloat(width) / CGFloat(height), 0.5), 1.9)
        }
        return 16.0 / 9.0
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
    }

    private var initials: String {
        let name = author.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "?" : String(name.prefix(1)).uppercased()
    }
}

// MARK: - X / Twitter

struct XPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let onPlay: (URL) -> Void

    private enum Palette {
        static let card = Color.white
        static let text = Color(red: 0.06, green: 0.06, blue: 0.07)
        static let secondary = Color(red: 0.325, green: 0.392, blue: 0.443)
        static let blue = Color(red: 0.114, green: 0.631, blue: 0.949)
        static let border = Color(red: 0.90, green: 0.92, blue: 0.93)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ReplicaAvatar(author: manifest.author, size: 48)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(manifest.author.displayName).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.text)
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundStyle(Palette.blue)
                    }
                    if let username = manifest.author.username {
                        Text("@\(username)").font(.system(size: 15)).foregroundStyle(Palette.secondary)
                    }
                }
                Spacer()
                Image(systemName: "xmark.square.fill").font(.system(size: 22)).foregroundStyle(Palette.text)
                    .accessibilityHidden(true)
            }
            if !manifest.text.isEmpty {
                Text(manifest.text)
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quote = manifest.quotedPost { quoteBlock(quote) }
            mediaBlock
            Text(timestamp)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
            Divider().overlay(Palette.border)
            actionRow
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.border, lineWidth: 1) }
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var mediaBlock: some View {
        if manifest.orderedMedia.count == 1, let media = manifest.orderedMedia.first {
            ReplicaMedia(archiveID: archiveID, record: media, cornerRadius: 16, onPlay: onPlay)
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.border, lineWidth: 1) }
        } else if !manifest.orderedMedia.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                    ReplicaMedia(archiveID: archiveID, record: media, cornerRadius: 4, mode: .square, onPlay: onPlay)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.border, lineWidth: 1) }
        }
    }

    private func quoteBlock(_ quote: QuotedPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quote.author.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
            Text(quote.text).font(.system(size: 14)).foregroundStyle(Palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.border, lineWidth: 1) }
    }

    private var actionRow: some View {
        HStack {
            ForEach(["bubble.left", "arrow.2.squarepath", "heart", "square.and.arrow.up"], id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Palette.secondary)
                if symbol != "square.and.arrow.up" { Spacer() }
            }
        }
        .accessibilityHidden(true)
    }

    private var timestamp: String {
        (manifest.timestamp ?? manifest.savedAt).formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - TikTok

struct TikTokPostReplica: View {
    let manifest: ArchiveManifest
    let archiveID: UUID
    let onPlay: (URL) -> Void

    private static let pink = Color(red: 0.996, green: 0.173, blue: 0.333)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let media = manifest.orderedMedia.first {
                ReplicaMedia(archiveID: archiveID, record: media, cornerRadius: 0, mode: .fill, onPlay: onPlay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("@\(manifest.author.username ?? manifest.author.displayName)")
                        .font(.system(size: 16, weight: .bold))
                    if !manifest.text.isEmpty {
                        Text(manifest.text).font(.system(size: 14)).lineLimit(3)
                    }
                    Label("original sound", systemImage: "music.note")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.white)
                .shadow(radius: 3)
                Spacer()
                VStack(spacing: 20) {
                    ReplicaAvatar(author: manifest.author, size: 46).overlay(Circle().stroke(.white, lineWidth: 2))
                    rail("heart.fill")
                    rail("ellipsis.bubble.fill")
                    rail("bookmark.fill")
                    rail("arrowshape.turn.up.right.fill")
                }
            }
            .padding(16)
        }
        .frame(height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func rail(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 26))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .accessibilityHidden(true)
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
        static let secondary = Color(red: 0.55, green: 0.55, blue: 0.58)
        static let border = Color(red: 0.90, green: 0.90, blue: 0.92)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ReplicaAvatar(author: manifest.author, size: 36)
                Text(manifest.author.username ?? manifest.author.displayName)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(Palette.text)
            }
            .padding(12)
            if let media = manifest.orderedMedia.first {
                ReplicaMedia(archiveID: archiveID, record: media, cornerRadius: 0, onPlay: onPlay)
                    .frame(maxHeight: 460)
                    .clipped()
            }
            HStack(spacing: 16) {
                Image(systemName: "heart")
                Image(systemName: "bubble.right")
                Image(systemName: "paperplane")
                Spacer()
                Image(systemName: "bookmark")
            }
            .font(.system(size: 22))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if !manifest.text.isEmpty {
                (Text((manifest.author.username ?? manifest.author.displayName) + "  ").font(.system(size: 14, weight: .semibold))
                    + Text(manifest.text).font(.system(size: 14)))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
            Text(timestamp)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .padding(12)
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.border, lineWidth: 1) }
        .environment(\.colorScheme, .light)
    }

    private var timestamp: String {
        (manifest.timestamp ?? manifest.savedAt).formatted(date: .abbreviated, time: .omitted).uppercased()
    }
}

// MARK: - Generic (every other source)

struct GenericPostReplica: View {
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
                        PlatformIcon(platform: manifest.platform, size: 16)
                        Text(L10n.value(manifest.platform.titleKey))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                }
                Spacer()
                Text((manifest.timestamp ?? manifest.savedAt), style: .date)
                    .font(.caption).foregroundStyle(StashyTheme.inkSecondary)
            }
            if !manifest.text.isEmpty {
                Text(manifest.text).font(.body).foregroundStyle(StashyTheme.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                ReplicaMedia(archiveID: archiveID, record: media, cornerRadius: 16, onPlay: onPlay)
                    .frame(maxHeight: 440)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(16)
        .background(StashyTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.28), lineWidth: 1) }
    }
}
