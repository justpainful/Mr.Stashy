import SwiftUI
import UIKit

/// A saved post, shown on its own platform's terms.
///
/// The screen belongs to the source: its canvas runs edge to edge, its top bar is the one that
/// platform puts above a post, and the post fills the width the way it did in the app it came
/// from. What was here before was a card floating on Stashy's cream background — the frame around
/// it was the giveaway, and no amount of fidelity inside the card could undo it.
///
/// One strip at the bottom stays Stashy's, deliberately. It says which source this was, when it
/// was kept, and holds the archive tools. Nothing about the replica pretends the post is live, and
/// that strip is what keeps the difference visible without breaking the illusion above it.
struct LivingPostView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let archiveID: UUID
    @State private var manifest: ArchiveManifest?
    @State private var error: Error?
    @State private var exportedStash: ExportedStash?
    @State private var actionMessage: String?
    @State private var player: PlayerItem?

    private struct ExportedStash: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var skin: PlatformSkin {
        PlatformSkin.skin(for: manifest?.platform ?? .directMedia)
    }

    var body: some View {
        ZStack {
            skin.background.ignoresSafeArea()
            Group {
                if let manifest {
                    surface(manifest)
                } else if let error {
                    ContentUnavailableView(
                        L10n.value("livingPost.unavailable"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                } else {
                    ProgressView().tint(skin.text)
                }
            }
        }
        // The replica draws the platform's own bar, so Stashy's must not sit above it.
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .environment(\.colorScheme, skin.scheme)
        .task(id: archiveID) {
            do { manifest = try await appState.archiveStore.loadManifest(id: archiveID) }
            catch { self.error = error }
        }
        .fullScreenCover(item: $player) { item in
            FullScreenVideoPlayer(url: item.url)
        }
        .sheet(item: $exportedStash) { item in
            ShareSheet(url: item.url)
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

    @ViewBuilder private func surface(_ manifest: ArchiveManifest) -> some View {
        let onPlay: (URL) -> Void = { url in player = PlayerItem(url: url) }
        if skin.isImmersive {
            // Media runs under the chrome, so the controls float over it rather than pushing it
            // down — which is exactly how the source presents this kind of post.
            replica(manifest, onPlay: onPlay)
                .ignoresSafeArea()
                .overlay(alignment: .top) { immersiveBar }
                .overlay(alignment: .bottom) { archiveStrip(manifest) }
        } else {
            ScrollView {
                replica(manifest, onPlay: onPlay)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { platformBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { archiveStrip(manifest) }
        }
    }

    @ViewBuilder private func replica(_ manifest: ArchiveManifest, onPlay: @escaping (URL) -> Void) -> some View {
        switch manifest.platform {
        case .x:
            XPostReplica(manifest: manifest, archiveID: archiveID, skin: skin, onPlay: onPlay)
        case .tikTok:
            TikTokPostReplica(manifest: manifest, archiveID: archiveID, skin: skin, onPlay: onPlay)
        case .instagram, .threads:
            InstagramPostReplica(manifest: manifest, archiveID: archiveID, skin: skin, onPlay: onPlay)
        default:
            BrandedPostReplica(manifest: manifest, archiveID: archiveID, skin: skin, onPlay: onPlay)
        }
    }

    // MARK: - The platform's own bar

    private var platformBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .replicaFont(17, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(skin.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(L10n.value("action.done")))

            Text(L10n.value(skin.barTitleKey))
                .replicaFont(17, weight: .bold, relativeTo: .headline)
                .foregroundStyle(skin.text)
            Spacer(minLength: 0)
            PlatformIcon(platform: manifest?.platform ?? .directMedia, size: 26, isDecorative: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            skin.background
                .overlay(alignment: .bottom) { Rectangle().fill(skin.separator).frame(height: 0.5) }
                .ignoresSafeArea(edges: .top)
        }
    }

    /// The floating pair a full-bleed post gets instead of a bar.
    private var immersiveBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(Text(L10n.value("action.done")))
            Spacer()
            PlatformIcon(platform: manifest?.platform ?? .directMedia, size: 30, isDecorative: true)
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    // MARK: - The strip that stays Stashy's

    private func archiveStrip(_ manifest: ArchiveManifest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.subheadline)
                .foregroundStyle(StashyTheme.accent(for: appState.settings.theme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.format("livingPost.keptFrom", L10n.value(manifest.platform.titleKey)))
                    .font(.caption.weight(.semibold))
                Text(L10n.date(manifest.savedAt, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            menu(manifest)
            Button(L10n.value("action.done")) { dismiss() }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("livingPost.done")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Stashy's own material, deliberately: this strip is the one part of the screen that is
        // not pretending to be the source.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .environment(\.colorScheme, appState.settings.appearance.resolvedScheme)
        .tint(StashyTheme.accent(for: appState.settings.theme))
        .accessibilityIdentifier("livingPost.archiveStrip")
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
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(Text(L10n.value("livingPost.title")))
        .accessibilityIdentifier("livingPost.menu")
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
            // Present the share sheet straight away. Waiting for the person to reopen a menu
            // they have no reason to reopen is not feedback.
            exportedStash = ExportedStash(url: destination)
        } catch {
            actionMessage = error.localizedDescription
        }
    }
}

extension UserSettings.Appearance {
    /// The scheme Stashy's own chrome uses, independent of whatever skin the replica imposes.
    var resolvedScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }
    }
}

/// `UIActivityViewController`, so an exported package can be handed straight to Files, AirDrop,
/// or Messages without a second tap through a menu.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
