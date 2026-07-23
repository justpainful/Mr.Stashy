import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var mode: LibraryMode = .posts
    @State private var query = ""
    @State private var selectedPlatform: Platform?
    @State private var selectedMediaType: MediaType?
    @State private var entries: [ArchivedPostSummary] = []
    @State private var mediaEntries: [ArchivedMediaSummary] = []
    @State private var archivePendingDeletion: ArchivedPostSummary?
    @State private var presentedArchive: ArchiveRoute?

    private enum LibraryMode: String, CaseIterable, Identifiable { case posts, media; var id: String { rawValue } }
    private struct ArchiveRoute: Identifiable {
        let archiveID: UUID
        var id: UUID { archiveID }
    }

    var body: some View {
        ZStack {
            StashyBackground()
            VStack(spacing: 14) {
                Picker(String(localized: "library.mode"), selection: $mode) {
                    ForEach(LibraryMode.allCases) { mode in Text(L10n.value("library.mode.\(mode.rawValue)")).tag(mode) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                searchField
                filters
                content
            }
        }
        .navigationTitle(String(localized: "tab.library"))
        .task { await refreshEntries() }
        .task(id: query) { await refreshEntries() }
        .task(id: mode) { await refreshEntries() }
        .onChange(of: appState.libraryPosts) { _, posts in
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if mode == .posts {
                entries = posts
            } else {
                Task { await refreshEntries() }
            }
        }
        .confirmationDialog(String(localized: "library.delete.title"), isPresented: Binding(get: { archivePendingDeletion != nil }, set: { if !$0 { archivePendingDeletion = nil } })) {
            Button(String(localized: "library.delete.confirm"), role: .destructive) {
                guard let archive = archivePendingDeletion else { return }
                Task { await delete(archive) }
            }
            Button(String(localized: "action.cancel"), role: .cancel) { archivePendingDeletion = nil }
        } message: {
            Text(String(localized: "library.delete.message"))
        }
        .sheet(item: $presentedArchive) { route in
            NavigationStack {
                LivingPostView(archiveID: route.archiveID)
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    private var searchField: some View {
        TextField(String(localized: "library.search"), text: $query)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StashyTheme.charcoal.opacity(0.2), lineWidth: 1))
            .padding(.horizontal, 20)
            .accessibilityIdentifier("library.search")
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker(String(localized: "library.filter.platform"), selection: $selectedPlatform) {
                Text(String(localized: "library.filter.allPlatforms")).tag(Platform?.none)
                ForEach(availablePlatforms) { platform in
                    Text(L10n.value(platform.titleKey)).tag(Optional(platform))
                }
            }
            .pickerStyle(.menu)

            if mode == .media {
                Picker(String(localized: "library.filter.mediaType"), selection: $selectedMediaType) {
                    Text(String(localized: "library.filter.allMedia")).tag(MediaType?.none)
                    ForEach(MediaType.allCases) { type in
                        Label(L10n.value("media.\(type.rawValue)"), systemImage: type.systemImage)
                            .tag(Optional(type))
                    }
                }
                .pickerStyle(.menu)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var content: some View {
        if (mode == .posts && filteredEntries.isEmpty) || (mode == .media && filteredMediaEntries.isEmpty) {
            VStack(spacing: 14) {
                StashyIllustration(name: "libraryEmpty", maxHeight: 220)
                Label(L10n.value(mode == .posts ? "library.empty.posts" : "library.empty.media"), systemImage: mode == .posts ? "archivebox" : "photo.on.rectangle")
                    .font(.title3.weight(.bold))
                Text(String(localized: "library.empty.body"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        } else {
            List {
                if mode == .posts {
                    ForEach(filteredEntries) { item in
                        Button { presentedArchive = ArchiveRoute(archiveID: item.id) } label: { PostRow(summary: item) }
                            .buttonStyle(.plain)
                            .swipeActions { deleteAction(item) }
                    }
                } else {
                    ForEach(filteredMediaEntries) { item in
                        Button { presentedArchive = ArchiveRoute(archiveID: item.archiveID) } label: { MediaRow(item: item) }
                            .buttonStyle(.plain)
                            .swipeActions { deleteAction(ArchivedPostSummary(id: item.archiveID, platform: item.platform, author: item.author, text: "", mediaCount: 1, savedAt: item.savedAt, localFolderName: item.archiveID.uuidString)) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func refreshEntries() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .posts {
            entries = await appState.archiveStore.loadSummaries(matching: trimmed.isEmpty ? nil : trimmed)
        } else {
            mediaEntries = await appState.archiveStore.loadMediaSummaries(matching: trimmed.isEmpty ? nil : trimmed)
        }
    }

    @ViewBuilder private func deleteAction(_ archive: ArchivedPostSummary) -> some View {
        Button(role: .destructive) { archivePendingDeletion = archive } label: {
            Label(String(localized: "action.delete"), systemImage: "trash")
        }
    }

    private var filteredEntries: [ArchivedPostSummary] {
        guard let selectedPlatform else { return entries }
        return entries.filter { $0.platform == selectedPlatform }
    }

    private var filteredMediaEntries: [ArchivedMediaSummary] {
        mediaEntries.filter { item in
            (selectedPlatform == nil || item.platform == selectedPlatform) &&
                (selectedMediaType == nil || item.type == selectedMediaType)
        }
    }

    private var availablePlatforms: [Platform] {
        let values = mode == .posts ? entries.map(\.platform) : mediaEntries.map(\.platform)
        return Array(Set(values)).sorted { L10n.value($0.titleKey) < L10n.value($1.titleKey) }
    }

    private func delete(_ archive: ArchivedPostSummary) async {
        do {
            try await appState.archiveStore.deleteArchive(id: archive.id)
            appState.libraryPosts = await appState.archiveStore.loadSummaries()
            await refreshEntries()
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
        archivePendingDeletion = nil
    }
}

private struct PostRow: View {
    let summary: ArchivedPostSummary
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: summary.platform == .directMedia ? "link" : "archivebox")
                .font(.title2).foregroundStyle(StashyTheme.lavender)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.author).font(.headline)
                Text(summary.text.isEmpty ? String(localized: "library.mediaOnly") : summary.text).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                Text(L10n.format("library.mediaCount", Int64(summary.mediaCount)))
                    .font(.caption).foregroundStyle(StashyTheme.green)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct MediaRow: View {
    let item: ArchivedMediaSummary
    var body: some View {
        HStack {
            Image(systemName: item.type.systemImage).foregroundStyle(StashyTheme.aqua)
            VStack(alignment: .leading) {
                Text(item.author).font(.headline)
                Text(String(localized: "library.mediaBacklink"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let fileSize = item.fileSize {
                Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
