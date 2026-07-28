import SwiftUI

struct LivingPostView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let archiveID: UUID
    @State private var manifest: ArchiveManifest?
    @State private var error: Error?
    @State private var exportedStashURL: URL?
    /// Kept apart from `error`, which replaces the whole screen. An export that fails has to be
    /// reported without discarding the archive the person is looking at — previously it was
    /// simply swallowed and the button appeared to do nothing.
    @State private var actionMessage: String?

    var body: some View {
        ZStack {
            StashyBackground()
            Group {
                if let manifest { content(manifest) }
                else if let error { ContentUnavailableView(L10n.value("livingPost.unavailable"), systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription)) }
                else { ProgressView(L10n.value("livingPost.loading")) }
            }
        }
        .navigationTitle(L10n.value("livingPost.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.value("action.done")) { dismiss() }
            }
        }
        .task(id: archiveID) {
            do { manifest = try await appState.archiveStore.loadManifest(id: archiveID) }
            catch { self.error = error }
        }
        .alert(
            L10n.value("error.title"),
            isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })
        ) {
            Button(L10n.value("action.done")) { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    private func content(_ manifest: ArchiveManifest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourcePostCard(manifest)
                StashyGlassBar {
                    Link(destination: manifest.canonicalURL) { Label(L10n.value("livingPost.openOriginal"), systemImage: "safari") }.buttonStyle(.glass)
                    Button { UIPasteboard.general.url = manifest.canonicalURL } label: { Label(L10n.value("livingPost.copySource"), systemImage: "doc.on.doc") }.buttonStyle(.glass)
                }
                HStack {
                    Button { Task { await exportStash() } } label: {
                        Label(L10n.value("livingPost.exportStash"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                    if let exportedStashURL {
                        ShareLink(item: exportedStashURL) {
                            Label(L10n.value("livingPost.shareStash"), systemImage: "square.and.arrow.up.on.square")
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .padding(20)
        }
    }

    private func sourcePostCard(_ manifest: ArchiveManifest) -> some View {
        let style = manifest.platform.sourceStyle
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                sourceAvatar(manifest.author, accent: style.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(manifest.author.displayName).font(.headline)
                    if let username = manifest.author.username {
                        Text("@\(username)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        PlatformIcon(platform: manifest.platform, size: 18)
                        Text(L10n.value(manifest.platform.titleKey))
                    }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.accent)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(style.accent)
                        .accessibilityHidden(true)
                    Text(manifest.timestamp ?? manifest.savedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !manifest.text.isEmpty {
                Text(manifest.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            if let quote = manifest.quotedPost { QuotedPostView(quote: quote) }
            ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                LocalMediaCard(archiveID: archiveID, record: media, style: style, embedded: true)
            }
        }
        .padding(16)
        .background(style.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(style.accent.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func sourceAvatar(_ author: ResolvedAuthor, accent: Color) -> some View {
        if let avatarURL = author.avatarURL {
            AsyncImage(url: avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(accent)
            }
            .frame(width: 48, height: 48)
            .clipShape(.circle)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)
        }
    }

    private func exportStash() async {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Stashy-\(archiveID.uuidString).stash")
        do {
            try await appState.archiveStore.exportStash(id: archiveID, to: destination)
            exportedStashURL = destination
        } catch {
            actionMessage = error.localizedDescription
        }
    }
}

private struct LocalMediaCard: View {
    @Environment(AppState.self) private var appState
    let archiveID: UUID
    let record: ArchivedMediaRecord
    let style: SourceStyle
    var embedded = false
    @State private var localURL: URL?
    @State private var savedToPhotos = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: record.type.systemImage).font(.title2).foregroundStyle(style.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.value("media.\(record.type.rawValue)")).font(.headline)
                    Text(record.checksumSHA256 ?? L10n.value("livingPost.pendingChecksum")).font(.caption2.monospaced()).lineLimit(1)
                }
                Spacer()
                Image(systemName: localURL == nil ? "exclamationmark.triangle" : "checkmark.seal.fill")
                    .foregroundStyle(localURL == nil ? StashyTheme.pink : StashyTheme.green)
            }
            if let localURL {
                ArchivedMediaPreview(url: localURL, type: record.type)
                if record.type != .audio {
                    Button {
                        Task { await saveToPhotos(localURL) }
                    } label: {
                        Label(L10n.value(savedToPhotos ? "livingPost.savedToPhotos" : "livingPost.saveToPhotos"), systemImage: savedToPhotos ? "checkmark" : "photo.badge.arrow.down")
                    }
                        .buttonStyle(.glass)
                }
                ShareLink(item: localURL) {
                    Label(L10n.value("livingPost.shareMedia"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(embedded ? 0 : 14)
        .background {
            if !embedded { RoundedRectangle(cornerRadius: 18).fill(style.accent.opacity(0.08)) }
        }
        .overlay {
            if !embedded { RoundedRectangle(cornerRadius: 18).stroke(style.accent.opacity(0.28), lineWidth: 1) }
        }
        .task(id: record.localFilename) {
            guard let filename = record.localFilename else { return }
            localURL = await appState.archiveStore.localMediaURL(archiveID: archiveID, filename: filename)
        }
        .contextMenu {
            if let localURL {
                if record.type != .audio {
                    Button {
                        Task { await saveToPhotos(localURL) }
                    } label: {
                        Label(L10n.value("livingPost.saveToPhotos"), systemImage: "photo.badge.arrow.down")
                    }
                }
                ShareLink(item: localURL) {
                    Label(L10n.value("livingPost.shareMedia"), systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func saveToPhotos(_ url: URL) async {
        do {
            try await PhotoLibrarySaver.save(url: url, type: record.type)
            savedToPhotos = true
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
    }
}
