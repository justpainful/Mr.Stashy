import SwiftUI

struct ResultsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let post: ResolvedPost
    @State private var selectedMediaIDs: Set<UUID>
    @State private var showTextCard = false
    @State private var pendingSaveMode: QueueItem.SaveMode?

    /// Whether this post is already in the queue. Derived from the queue rather than held in
    /// view state, so it survives navigating away and back — and so it clears again when a save
    /// fails, instead of leaving both buttons permanently disabled.
    private var queuedItem: QueueItem? {
        appState.queueItems.first { $0.post.id == post.id && !$0.stage.isFinished }
    }
    private var queuedMode: QueueItem.SaveMode? { queuedItem?.mode }

    init(post: ResolvedPost) {
        self.post = post
        _selectedMediaIDs = State(initialValue: Set(post.media.map(\.id)))
    }

    var body: some View {
        ZStack {
            StashyBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    authorBlock
                    Link(destination: post.canonicalURL) {
                        Label(post.canonicalURL.host ?? post.canonicalURL.absoluteString, systemImage: "link")
                            .font(.caption)
                    }
                    ForEach(Array(post.warnings.enumerated()), id: \.offset) { _, warning in
                        ResolverWarningRow(text: warning)
                    }
                    if !post.text.isEmpty { Text(post.text).textSelection(.enabled).font(.body) }
                    if let quote = post.quotedPost { QuotedPostView(quote: quote) }
                    mediaList
                    actionBar
                    if let queuedMode { savedConfirmation(queuedMode) }
                }
                .padding(20)
            }
        }
        .navigationTitle(L10n.value("results.title"))
        .sheet(isPresented: $showTextCard) { TextCardComposer(post: post) }
        .confirmationDialog(L10n.value("results.quality.title"), isPresented: Binding(
            get: { pendingSaveMode != nil },
            set: { if !$0 { pendingSaveMode = nil } }
        )) {
            Button(L10n.value("settings.quality.original")) { enqueuePending(quality: .original) }
            Button(L10n.value("settings.quality.dataSaver")) { enqueuePending(quality: .dataSaver) }
            Button(L10n.value("action.cancel"), role: .cancel) { pendingSaveMode = nil }
        } message: {
            Text(L10n.value("results.quality.message"))
        }
    }

    /// Saving happens in the queue, so the screen has to say the save started; otherwise the
    /// only feedback is a tab badge the person may never look at.
    private func savedConfirmation(_ mode: QueueItem.SaveMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(L10n.value(mode == .fullPost ? "results.queued.fullPost" : "results.queued.mediaOnly"))
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(StashyTheme.green)
            }
            HStack(spacing: 12) {
                Button {
                    appState.selectedTab = .queue
                    dismiss()
                } label: {
                    Label(L10n.value("results.openQueue"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glassProminent)
                Button {
                    appState.selectedTab = .library
                    dismiss()
                } label: {
                    Label(L10n.value("tab.library"), systemImage: "books.vertical")
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular.tint(StashyTheme.green.opacity(0.16)), in: .rect(cornerRadius: 20))
        .accessibilityIdentifier("results.queued")
    }

    private var authorBlock: some View {
        HStack(spacing: 12) {
            Group {
                if let avatarURL = post.author.avatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(StashyTheme.lavender)
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.author.displayName).font(.headline)
                if let username = post.author.username { Text("@\(username)").font(.subheadline).foregroundStyle(StashyTheme.inkSecondary) }
                HStack(spacing: 5) {
                    PlatformIcon(platform: post.platform, size: 17)
                    Text(L10n.value(post.platform.titleKey))
                }
                .font(.caption.weight(.medium))
            }
            Spacer()
            if let date = post.createdAt { Text(date, style: .date).font(.caption).foregroundStyle(StashyTheme.inkSecondary) }
        }
        .accessibilityElement(children: .combine)
    }

    private var sortedMedia: [ResolvedMedia] { post.media.sorted { $0.orderIndex < $1.orderIndex } }

    @ViewBuilder private var mediaList: some View {
        if sortedMedia.isEmpty {
            EmptyView()
        } else if sortedMedia.count == 1, let media = sortedMedia.first {
            // A single item gets a large preview with its details underneath, so the review is
            // the media itself rather than one word describing it.
            VStack(alignment: .leading, spacing: 8) {
                MediaSelectionCard(media: media, isSelected: selectedMediaIDs.contains(media.id), ratio: previewRatio(for: media)) {
                    toggle(media)
                }
                Text(MediaCardMetadata.summary(for: media))
                    .font(.caption)
                    .foregroundStyle(StashyTheme.inkSecondary)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(sortedMedia) { media in
                    MediaSelectionCard(media: media, isSelected: selectedMediaIDs.contains(media.id), ratio: 1) {
                        toggle(media)
                    }
                }
            }
        }
    }

    private func toggle(_ media: ResolvedMedia) {
        if selectedMediaIDs.contains(media.id) {
            selectedMediaIDs.remove(media.id)
        } else {
            selectedMediaIDs.insert(media.id)
        }
    }

    /// A single-item preview follows the media's own shape, clamped so an extreme aspect ratio
    /// cannot make the card fill the whole screen.
    private func previewRatio(for media: ResolvedMedia) -> CGFloat {
        if let width = media.width, let height = media.height, width > 0, height > 0 {
            return min(max(CGFloat(width) / CGFloat(height), 0.6), 1.6)
        }
        return media.type == .video ? 16.0 / 9.0 : 3.0 / 4.0
    }

    private var actionBar: some View {
        StashyGlassBar {
            saveButtons
            Button { showTextCard = true } label: { Label(L10n.value("results.textCard"), systemImage: "text.badge.plus") }
                .buttonStyle(.glass)
                .disabled(post.text.isEmpty)
                .accessibilityIdentifier("results.textCard")
        }
    }

    @ViewBuilder private var saveButtons: some View {
        if appState.settings.saveMode == .mediaOnly {
            fullPostButton.buttonStyle(.glass)
            mediaOnlyButton.buttonStyle(.glassProminent)
        } else {
            fullPostButton.buttonStyle(.glassProminent)
            mediaOnlyButton.buttonStyle(.glass)
        }
    }

    private var fullPostButton: some View {
        Button { requestSave(.fullPost) } label: {
            Label(L10n.value("results.saveFull"), systemImage: "archivebox")
        }
        .disabled(queuedMode != nil || (selectedMediaIDs.isEmpty && !post.media.isEmpty))
        .accessibilityIdentifier("results.saveFull")
    }

    private var mediaOnlyButton: some View {
        Button { requestSave(.mediaOnly) } label: {
            Label(L10n.value("results.saveMedia"), systemImage: "arrow.down.to.line")
        }
        .disabled(queuedMode != nil || selectedMediaIDs.isEmpty)
        .accessibilityIdentifier("results.saveMedia")
    }

    private func requestSave(_ mode: QueueItem.SaveMode) {
        guard queuedMode == nil else { return }
        if appState.settings.quality == .askEveryTime {
            pendingSaveMode = mode
        } else {
            enqueue(mode: mode, quality: appState.settings.quality)
        }
    }

    private func enqueuePending(quality: UserSettings.Quality) {
        guard let mode = pendingSaveMode else { return }
        pendingSaveMode = nil
        enqueue(mode: mode, quality: quality)
    }

    private func enqueue(mode: QueueItem.SaveMode, quality: UserSettings.Quality) {
        switch mode {
        case .fullPost: appState.enqueueFullPost(post, selectedIDs: selectedMediaIDs, quality: quality)
        case .mediaOnly: appState.enqueueMediaOnly(post, selectedIDs: selectedMediaIDs, quality: quality)
        }
    }
}

/// One selectable media card: the real preview, a selection tick, and a highlighted border
/// when chosen. Tapping toggles whether the item is included in the save.
private struct MediaSelectionCard: View {
    let media: ResolvedMedia
    let isSelected: Bool
    var ratio: CGFloat = 1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RemoteMediaThumbnail(media: media)
                .aspectRatio(ratio, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(
                            isSelected ? Color.white : Color.white.opacity(0.95),
                            isSelected ? StashyTheme.green : Color.black.opacity(0.32)
                        )
                        .padding(8)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? StashyTheme.green : Color.clear, lineWidth: 3)
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        // Each card names the item it belongs to and reports its own selected state, so the
        // grid is navigable rather than a run of identically labelled buttons.
        .accessibilityLabel(Text(L10n.format(
            "media.selection.item",
            Int64(media.orderIndex + 1),
            media.type.shortLabel
        )))
        .accessibilityValue(Text(MediaCardMetadata.summary(for: media)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("results.media.\(media.orderIndex)")
    }
}

/// Builds the one-line technical summary shown under a single-item preview.
enum MediaCardMetadata {
    static func summary(for media: ResolvedMedia) -> String {
        var values: [String] = [media.type.shortLabel]
        if let width = media.width, let height = media.height {
            values.append("\(width) × \(height)")
        }
        if let duration = media.duration {
            values.append(ThumbnailBadge.durationText(duration))
        }
        if let variant = media.highestVariant {
            if let codec = variant.codec, !codec.isEmpty { values.append(codec.uppercased()) }
            if let bytes = variant.estimatedBytes { values.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        }
        return values.joined(separator: " · ")
    }
}

struct QuotedPostView: View {
    let quote: QuotedPost
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(quote.author.displayName).font(.subheadline.weight(.semibold))
            Text(quote.text).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StashyTheme.hairline, lineWidth: 1))
    }
}
