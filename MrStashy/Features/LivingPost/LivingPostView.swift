import SwiftUI

struct LivingPostView: View {
    @Environment(AppState.self) private var appState
    let archiveID: UUID
    @State private var manifest: ArchiveManifest?
    @State private var error: Error?
    @State private var exportedStashURL: URL?

    var body: some View {
        ZStack {
            StashyBackground()
            Group {
                if let manifest { content(manifest) }
                else if let error { ContentUnavailableView(String(localized: "livingPost.unavailable"), systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription)) }
                else { ProgressView(String(localized: "livingPost.loading")) }
            }
        }
        .navigationTitle(String(localized: "livingPost.title"))
        .task(id: archiveID) {
            do { manifest = try await appState.archiveStore.loadManifest(id: archiveID) }
            catch { self.error = error }
        }
    }

    private func content(_ manifest: ArchiveManifest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(StashyTheme.lavender)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(manifest.author.displayName).font(.headline)
                        Text(L10n.value(manifest.platform.titleKey)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(manifest.savedAt, style: .date).font(.caption)
                }
                if !manifest.text.isEmpty { Text(manifest.text).textSelection(.enabled) }
                if let quote = manifest.quotedPost { QuotedPostView(quote: quote) }
                LazyVStack(spacing: 12) {
                    ForEach(manifest.orderedMedia, id: \.mediaID) { media in
                        LocalMediaCard(archiveID: archiveID, record: media)
                    }
                }
                StashyGlassBar {
                    Link(destination: manifest.canonicalURL) { Label(String(localized: "livingPost.openOriginal"), systemImage: "safari") }.buttonStyle(.glass)
                    Button { UIPasteboard.general.url = manifest.canonicalURL } label: { Label(String(localized: "livingPost.copySource"), systemImage: "doc.on.doc") }.buttonStyle(.glass)
                }
                HStack {
                    Button { Task { await exportStash() } } label: {
                        Label(String(localized: "livingPost.exportStash"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                    if let exportedStashURL {
                        ShareLink(item: exportedStashURL) {
                            Label(String(localized: "livingPost.shareStash"), systemImage: "square.and.arrow.up.on.square")
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .padding(20)
        }
    }

    private func exportStash() async {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Stashy-\(archiveID.uuidString).stash")
        do {
            try await appState.archiveStore.exportStash(id: archiveID, to: destination)
            exportedStashURL = destination
        } catch {
            self.error = error
        }
    }
}

private struct LocalMediaCard: View {
    @Environment(AppState.self) private var appState
    let archiveID: UUID
    let record: ArchivedMediaRecord
    @State private var localURL: URL?
    @State private var savedToPhotos = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: record.type.systemImage).font(.title2).foregroundStyle(StashyTheme.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.value("media.\(record.type.rawValue)")).font(.headline)
                    Text(record.checksumSHA256 ?? String(localized: "livingPost.pendingChecksum")).font(.caption2.monospaced()).lineLimit(1)
                }
                Spacer()
                Image(systemName: localURL == nil ? "exclamationmark.triangle" : "checkmark.seal.fill")
                    .foregroundStyle(localURL == nil ? StashyTheme.pink : StashyTheme.green)
            }
            if let localURL {
                ArchivedMediaPreview(url: localURL, type: record.type)
                if record.type != .audio {
                    Button {
                        Task {
                            do {
                                try await PhotoLibrarySaver.save(url: localURL, type: record.type)
                                savedToPhotos = true
                            } catch {
                                appState.lastError = UserVisibleError(message: error.localizedDescription)
                            }
                        }
                    } label: {
                        Label(L10n.value(savedToPhotos ? "livingPost.savedToPhotos" : "livingPost.saveToPhotos"), systemImage: savedToPhotos ? "checkmark" : "photo.badge.arrow.down")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(14)
        .background(StashyTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(StashyTheme.charcoal.opacity(0.12), lineWidth: 1))
        .task(id: record.localFilename) {
            guard let filename = record.localFilename else { return }
            localURL = await appState.archiveStore.localMediaURL(archiveID: archiveID, filename: filename)
        }
    }
}
