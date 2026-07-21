import SwiftUI

struct ResultsView: View {
    @Environment(AppState.self) private var appState
    let post: ResolvedPost
    @State private var selectedMediaIDs: Set<UUID>
    @State private var showTextCard = false

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
                    if !post.text.isEmpty { Text(post.text).textSelection(.enabled).font(.body) }
                    if let quote = post.quotedPost { QuotedPostView(quote: quote) }
                    mediaList
                    actionBar
                }
                .padding(20)
            }
        }
        .navigationTitle(String(localized: "results.title"))
        .sheet(isPresented: $showTextCard) { TextCardComposer(post: post) }
    }

    private var authorBlock: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 42)).foregroundStyle(StashyTheme.lavender)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.author.displayName).font(.headline)
                if let username = post.author.username { Text("@\(username)").font(.subheadline).foregroundStyle(.secondary) }
                Label(L10n.value(post.platform.titleKey), systemImage: "link")
                    .font(.caption.weight(.medium))
            }
            Spacer()
            if let date = post.createdAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
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
            Button {
                appState.enqueueFullPost(post, selectedIDs: selectedMediaIDs)
            } label: { Label(String(localized: "results.saveFull"), systemImage: "archivebox") }
            .buttonStyle(.glassProminent)
            .disabled(selectedMediaIDs.isEmpty && !post.media.isEmpty)
            .accessibilityIdentifier("results.saveFull")
            Button {
                appState.enqueueMediaOnly(post, selectedIDs: selectedMediaIDs)
            } label: { Label(String(localized: "results.saveMedia"), systemImage: "arrow.down.to.line") }
            .buttonStyle(.glass)
            .disabled(selectedMediaIDs.isEmpty)
            Button { showTextCard = true } label: { Label(String(localized: "results.textCard"), systemImage: "text.badge.plus") }
                .buttonStyle(.glass)
                .accessibilityIdentifier("results.textCard")
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
                    Text(metadata).font(.caption).foregroundStyle(.secondary)
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
        .accessibilityLabel(Text(String(localized: "media.selection")))
    }
    private var metadata: String {
        let dimensions = [media.width, media.height].compactMap { $0 }.count == 2 ? "\(media.width ?? 0) × \(media.height ?? 0)" : String(localized: "media.unknownDimensions")
        return dimensions
    }
}

private struct QuotedPostView: View {
    let quote: QuotedPost
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(quote.author.displayName).font(.subheadline.weight(.semibold))
            Text(quote.text).font(.subheadline)
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StashyTheme.charcoal.opacity(0.18), lineWidth: 1))
    }
}
