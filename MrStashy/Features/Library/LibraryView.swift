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
    @State private var scope: LibraryScope = .all
    @State private var showCreateCollection = false
    @State private var collectionName = ""

    private enum LibraryMode: String, CaseIterable, Identifiable { case posts, media; var id: String { rawValue } }
    private enum LibraryScope: Hashable { case all, pinned, collection(UUID) }
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
                organizationScopes
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
        .alert(String(localized: "library.collection.create"), isPresented: $showCreateCollection) {
            TextField(String(localized: "library.collection.name"), text: $collectionName)
            Button(String(localized: "action.cancel"), role: .cancel) { collectionName = "" }
            Button(String(localized: "library.collection.create")) {
                let name = collectionName
                collectionName = ""
                Task { await appState.createCollection(named: name) }
            }
        } message: {
            Text(String(localized: "library.collection.create.body"))
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

    private var organizationScopes: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ScopeChip(title: String(localized: "library.scope.all"), symbol: "square.grid.2x2", isSelected: scope == .all) {
                    scope = .all
                }
                ScopeChip(title: String(localized: "library.scope.pinned"), symbol: "pin.fill", isSelected: scope == .pinned) {
                    scope = .pinned
                }
                ForEach(appState.libraryOrganization.collections) { collection in
                    ScopeChip(title: collection.name, symbol: collection.symbol, isSelected: scope == .collection(collection.id)) {
                        scope = .collection(collection.id)
                    }
                }
                Button { showCreateCollection = true } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text(String(localized: "library.collection.create")))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var content: some View {
        if (mode == .posts && filteredEntries.isEmpty) || (mode == .media && filteredMediaEntries.isEmpty) {
            VStack(spacing: 14) {
                StashyIllustration(name: "stashyLibrary", maxHeight: 220)
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
                            .swipeActions(edge: .leading) { organizeActions(archiveID: item.id) }
                            .contextMenu { organizeMenu(archiveID: item.id) }
                    }
                } else {
                    ForEach(filteredMediaEntries) { item in
                        Button { presentedArchive = ArchiveRoute(archiveID: item.archiveID) } label: { MediaRow(item: item) }
                            .buttonStyle(.plain)
                            .swipeActions { deleteAction(ArchivedPostSummary(id: item.archiveID, platform: item.platform, author: item.author, text: "", mediaCount: 1, savedAt: item.savedAt, localFolderName: item.archiveID.uuidString)) }
                            .swipeActions(edge: .leading) { organizeActions(archiveID: item.archiveID) }
                            .contextMenu { organizeMenu(archiveID: item.archiveID) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.clear)
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
        entries.filter { item in
            (selectedPlatform == nil || item.platform == selectedPlatform) && isIncludedInScope(item.id)
        }
    }

    private var filteredMediaEntries: [ArchivedMediaSummary] {
        mediaEntries.filter { item in
            (selectedPlatform == nil || item.platform == selectedPlatform) &&
                (selectedMediaType == nil || item.type == selectedMediaType) &&
                isIncludedInScope(item.archiveID)
        }
    }

    private var availablePlatforms: [Platform] {
        let values = mode == .posts ? entries.map(\.platform) : mediaEntries.map(\.platform)
        return Array(Set(values)).sorted { L10n.value($0.titleKey) < L10n.value($1.titleKey) }
    }

    private func delete(_ archive: ArchivedPostSummary) async {
        do {
            try await appState.archiveStore.deleteArchive(id: archive.id)
            await appState.removeArchiveFromOrganization(archive.id)
            appState.libraryPosts = await appState.archiveStore.loadSummaries()
            await refreshEntries()
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
        archivePendingDeletion = nil
    }

    private func isIncludedInScope(_ archiveID: UUID) -> Bool {
        switch scope {
        case .all: true
        case .pinned: appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID)
        case .collection(let id): appState.libraryOrganization.contains(archiveID, in: id)
        }
    }

    @ViewBuilder private func organizeActions(archiveID: UUID) -> some View {
        Button {
            Task { await appState.togglePinned(archiveID: archiveID) }
        } label: {
            Label(
                String(localized: appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID) ? "library.unpin" : "library.pin"),
                systemImage: appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID) ? "pin.slash" : "pin"
            )
        }
        .tint(StashyTheme.butter)
    }

    @ViewBuilder private func organizeMenu(archiveID: UUID) -> some View {
        Button {
            Task { await appState.togglePinned(archiveID: archiveID) }
        } label: {
            Label(
                String(localized: appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID) ? "library.unpin" : "library.pin"),
                systemImage: appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID) ? "pin.slash" : "pin"
            )
        }
        if !appState.libraryOrganization.collections.isEmpty {
            Menu(String(localized: "library.collection.add")) {
                ForEach(appState.libraryOrganization.collections) { collection in
                    Button {
                        Task { await appState.toggleMembership(archiveID: archiveID, collectionID: collection.id) }
                    } label: {
                        Label(
                            collection.name,
                            systemImage: appState.libraryOrganization.contains(archiveID, in: collection.id) ? "checkmark" : collection.symbol
                        )
                    }
                }
            }
        }
    }
}

private struct ScopeChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(StashyTheme.aqua.opacity(0.32)).interactive() : .regular.interactive(), in: .capsule)
    }
}

private struct PostRow: View {
    @Environment(\.layoutDirection) private var layoutDirection
    let summary: ArchivedPostSummary
    var body: some View {
        HStack(spacing: 12) {
            PlatformIcon(platform: summary.platform, size: 36)
            VStack(alignment: layoutDirection == .rightToLeft ? .trailing : .leading, spacing: 4) {
                Text(summary.author).font(.headline)
                Text(summary.text.isEmpty ? String(localized: "library.mediaOnly") : summary.text).lineLimit(2).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(layoutDirection == .rightToLeft ? .trailing : .leading)
                Text(L10n.format("library.mediaCount", Int64(summary.mediaCount)))
                    .font(.caption).foregroundStyle(StashyTheme.green)
            }
            .frame(maxWidth: .infinity, alignment: layoutDirection == .rightToLeft ? .trailing : .leading)
        }
        .padding(.vertical, 5)
    }
}

private struct MediaRow: View {
    @Environment(\.layoutDirection) private var layoutDirection
    let item: ArchivedMediaSummary
    var body: some View {
        HStack(spacing: 10) {
            PlatformIcon(platform: item.platform, size: 30)
            Image(systemName: item.type.systemImage).foregroundStyle(StashyTheme.aqua)
            VStack(alignment: layoutDirection == .rightToLeft ? .trailing : .leading) {
                Text(item.author).font(.headline)
                Text(String(localized: "library.mediaBacklink"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: layoutDirection == .rightToLeft ? .trailing : .leading)
            Spacer()
            if let fileSize = item.fileSize {
                Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
