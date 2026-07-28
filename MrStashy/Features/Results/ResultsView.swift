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

    private var mediaList: some View {
        LazyVStack(spacing: 12) {
            ForEach(post.media.sorted(by: { $0.orderIndex < $1.orderIndex })) { media in
                MediaSelectionRow(media: media, isSelected: selectedMediaIDs.contains(media.id)) {
                    if selectedMediaIDs.contains(media.id) { selectedMediaIDs.remove(media.id) } else { selectedMediaIDs.insert(media.id) }
                }
            }
        }
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

private struct MediaSelectionRow: View {
    let media: ResolvedMedia
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: media.type.systemImage).font(.title2).foregroundStyle(StashyTheme.green).frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.value("media.\(media.type.rawValue)")).font(.headline)
                    Text(metadata).font(.caption).foregroundStyle(StashyTheme.inkSecondary)
                    if let variant = media.highestVariant {
                        Text(variant.qualityLabel).font(.caption2.weight(.semibold)).foregroundStyle(StashyTheme.green)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? StashyTheme.green : Color.secondary)
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        // Each row names the item it belongs to and reports its own selected state, so the
        // list is navigable rather than a run of identically labelled buttons.
        .accessibilityLabel(Text(L10n.format(
            "media.selection.item",
            Int64(media.orderIndex + 1),
            L10n.value("media.\(media.type.rawValue)")
        )))
        .accessibilityValue(Text(metadata))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("results.media.\(media.orderIndex)")
    }

    private var metadata: String {
        var values: [String] = []
        if let width = media.width, let height = media.height {
            values.append("\(width) × \(height)")
        } else {
            values.append(L10n.value("media.unknownDimensions"))
        }
        if let duration = media.duration {
            values.append(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
        }
        if let variant = media.highestVariant {
            if let codec = variant.codec, !codec.isEmpty { values.append(codec.uppercased()) }
            if let container = variant.container, !container.isEmpty { values.append(container.uppercased()) }
            if let bytes = variant.estimatedBytes { values.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            values.append(L10n.value(variant.cleanliness.titleKey))
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
