import SwiftUI
import UIKit

/// A saved post, shown as a faithful replica of how it looked on its source platform. The old
/// screen listed files and checksums; this one shows the post itself, and keeps the archive
/// tools (open original, copy link, save to Photos, export) in a single menu out of the way.
struct LivingPostView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let archiveID: UUID
    @State private var manifest: ArchiveManifest?
    @State private var error: Error?
    @State private var exportedStashURL: URL?
    @State private var actionMessage: String?
    @State private var player: PlayerItem?

    var body: some View {
        ZStack {
            StashyBackground()
            Group {
                if let manifest {
                    content(manifest)
                } else if let error {
                    ContentUnavailableView(L10n.value("livingPost.unavailable"), systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
                } else {
                    ProgressView(L10n.value("livingPost.loading"))
                }
            }
        }
        .navigationTitle(L10n.value("livingPost.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(L10n.value("action.done")) { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let manifest { menu(manifest) }
            }
        }
        .task(id: archiveID) {
            do { manifest = try await appState.archiveStore.loadManifest(id: archiveID) }
            catch { self.error = error }
        }
        .fullScreenCover(item: $player) { item in
            FullScreenVideoPlayer(url: item.url)
        }
        .alert(
            L10n.value("livingPost.title"),
            isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })
        ) {
            Button(L10n.value("action.done")) { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    private func content(_ manifest: ArchiveManifest) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                replica(manifest)
                Link(destination: manifest.canonicalURL) {
                    Label(L10n.value("livingPost.openOriginal"), systemImage: "safari")
                        .font(.footnote)
                }
                .foregroundStyle(StashyTheme.inkSecondary)
            }
            .padding(16)
        }
    }

    @ViewBuilder private func replica(_ manifest: ArchiveManifest) -> some View {
        let onPlay: (URL) -> Void = { url in player = PlayerItem(url: url) }
        switch manifest.platform {
        case .x:
            XPostReplica(manifest: manifest, archiveID: archiveID, onPlay: onPlay)
        case .tikTok:
            TikTokPostReplica(manifest: manifest, archiveID: archiveID, onPlay: onPlay)
        case .instagram, .threads:
            InstagramPostReplica(manifest: manifest, archiveID: archiveID, onPlay: onPlay)
        default:
            GenericPostReplica(manifest: manifest, archiveID: archiveID, onPlay: onPlay)
        }
    }

    private func menu(_ manifest: ArchiveManifest) -> some View {
        Menu {
            Link(destination: manifest.canonicalURL) {
                Label(L10n.value("livingPost.openOriginal"), systemImage: "safari")
            }
            Button {
                UIPasteboard.general.url = manifest.canonicalURL
            } label: {
                Label(L10n.value("livingPost.copySource"), systemImage: "doc.on.doc")
            }
            if manifest.orderedMedia.contains(where: { $0.type != .audio }) {
                Button {
                    Task { await saveAllToPhotos(manifest) }
                } label: {
                    Label(L10n.value("livingPost.saveToPhotos"), systemImage: "photo.badge.arrow.down")
                }
            }
            Button {
                Task { await exportStash() }
            } label: {
                Label(L10n.value("livingPost.exportStash"), systemImage: "square.and.arrow.up")
            }
            if let exportedStashURL {
                ShareLink(item: exportedStashURL) {
                    Label(L10n.value("livingPost.shareStash"), systemImage: "square.and.arrow.up.on.square")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func saveAllToPhotos(_ manifest: ArchiveManifest) async {
        var failure: String?
        for record in manifest.orderedMedia where record.type != .audio {
            guard let filename = record.localFilename,
                  let url = await appState.archiveStore.localMediaURL(archiveID: archiveID, filename: filename)
            else { continue }
            do { try await PhotoLibrarySaver.save(url: url, type: record.type) }
            catch { failure = error.localizedDescription }
        }
        actionMessage = failure ?? L10n.value("livingPost.savedToPhotos")
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
