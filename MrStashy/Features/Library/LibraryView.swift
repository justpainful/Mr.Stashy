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
                Picker(L10n.value("library.mode"), selection: $mode) {
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
        .navigationTitle(L10n.value("tab.library"))
        // One task keyed on everything that changes the result. Three separate tasks raced each
        // other on appearance and could leave the list showing an older query's rows.
        .task(id: refreshKey) {
            // A short pause collapses a burst of typing into one directory scan.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await refreshEntries()
        }
        .onChange(of: mode) { _, _ in
            // A platform chosen while browsing posts may not exist among media rows, which left
            // the picker showing a value that filtered everything away.
            selectedPlatform = nil
            selectedMediaType = nil
        }
        .confirmationDialog(L10n.value("library.delete.title"), isPresented: Binding(get: { archivePendingDeletion != nil }, set: { if !$0 { archivePendingDeletion = nil } })) {
            Button(L10n.value("library.delete.confirm"), role: .destructive) {
                guard let archive = archivePendingDeletion else { return }
                Task { await delete(archive) }
            }
            Button(L10n.value("action.cancel"), role: .cancel) { archivePendingDeletion = nil }
        } message: {
            Text(L10n.value("library.delete.message"))
        }
        .sheet(item: $presentedArchive) { route in
            NavigationStack {
                LivingPostView(archiveID: route.archiveID)
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .alert(L10n.value("library.collection.create"), isPresented: $showCreateCollection) {
            TextField(L10n.value("library.collection.name"), text: $collectionName)
            Button(L10n.value("action.cancel"), role: .cancel) { collectionName = "" }
            Button(L10n.value("library.collection.create")) {
                let name = collectionName
                collectionName = ""
                Task { await appState.createCollection(named: name) }
            }
        } message: {
            Text(L10n.value("library.collection.create.body"))
        }
    }

    private var searchField: some View {
        TextField(L10n.value("library.search"), text: $query)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StashyTheme.hairline, lineWidth: 1))
            .padding(.horizontal, 20)
            .accessibilityIdentifier("library.search")
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker(L10n.value("library.filter.platform"), selection: $selectedPlatform) {
                Text(L10n.value("library.filter.allPlatforms")).tag(Platform?.none)
                ForEach(availablePlatforms) { platform in
                    Text(L10n.value(platform.titleKey)).tag(Optional(platform))
                }
            }
            .pickerStyle(.menu)

            if mode == .media {
                Picker(L10n.value("library.filter.mediaType"), selection: $selectedMediaType) {
                    Text(L10n.value("library.filter.allMedia")).tag(MediaType?.none)
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
                ScopeChip(title: L10n.value("library.scope.all"), symbol: "square.grid.2x2", isSelected: scope == .all) {
                    scope = .all
                }
                ScopeChip(title: L10n.value("library.scope.pinned"), symbol: "pin.fill", isSelected: scope == .pinned) {
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
                .accessibilityLabel(Text(L10n.value("library.collection.create")))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var content: some View {
        if (mode == .posts && filteredEntries.isEmpty) || (mode == .media && filteredMediaEntries.isEmpty) {
            emptyState
        } else if mode == .posts {
            List {
                ForEach(filteredEntries) { item in
                    Button { presentedArchive = ArchiveRoute(archiveID: item.id) } label: { PostCard(summary: item, store: appState.archiveStore) }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions { deleteAction(item) }
                        .swipeActions(edge: .leading) { organizeActions(archiveID: item.id) }
                        .contextMenu { organizeMenu(archiveID: item.id) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.clear)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                    ForEach(filteredMediaEntries) { item in
                        Button { presentedArchive = ArchiveRoute(archiveID: item.archiveID) } label: {
                            LibraryMediaCell(item: item, store: appState.archiveStore)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.mediaItem")
                        // A media cell belongs to a post, and deleting it removes that whole
                        // post. The action says so rather than reading like a single-file delete.
                        .contextMenu {
                            organizeMenu(archiveID: item.archiveID)
                            Button(role: .destructive) {
                                archivePendingDeletion = ArchivedPostSummary(
                                    id: item.archiveID, platform: item.platform, author: item.author,
                                    text: "", mediaCount: 1, savedAt: item.savedAt,
                                    localFolderName: item.archiveID.uuidString
                                )
                            } label: {
                                Label(L10n.value("library.deletePost"), systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            StashyIllustration(name: "stashyLibrary", maxHeight: 220)
            Label(L10n.value(mode == .posts ? "library.empty.posts" : "library.empty.media"), systemImage: mode == .posts ? "archivebox" : "photo.on.rectangle")
                .font(.title3.weight(.bold))
            Text(L10n.value("library.empty.body"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    /// Everything that changes what the list should show, including the saved-post count so a
    /// finished download refreshes the rows without a second code path.
    private var refreshKey: String {
        // Content, not just the count: an archive that is overwritten keeps its identifier, so
        // a key built from identity alone would leave the row showing stale values.
        let fingerprint = appState.libraryPosts
            .map { "\($0.id.uuidString)-\($0.mediaCount)-\(Int($0.savedAt.timeIntervalSince1970))" }
            .joined(separator: ",")
            .hashValue
        return "\(mode.rawValue)|\(query)|\(fingerprint)"
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
            Label(L10n.value("action.delete"), systemImage: "trash")
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
                L10n.value(appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID) ? "library.unpin" : "library.pin"),
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
                L10n.value(appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID) ? "library.unpin" : "library.pin"),
                systemImage: appState.libraryOrganization.pinnedArchiveIDs.contains(archiveID) ? "pin.slash" : "pin"
            )
        }
        if !appState.libraryOrganization.collections.isEmpty {
            Menu(L10n.value("library.collection.add")) {
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

/// A saved-post row led by a real thumbnail of its first media, so the library reads as a
/// shelf of what was kept rather than a list of names.
private struct PostCard: View {
    @Environment(\.layoutDirection) private var layoutDirection
    let summary: ArchivedPostSummary
    let store: ArchiveStore
    @State private var lead: LeadMedia?

    private struct LeadMedia { let url: URL; let type: MediaType }

    var body: some View {
        HStack(spacing: 12) {
            leadThumbnail
                .frame(width: 76, height: 76)
            VStack(alignment: layoutDirection == .rightToLeft ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    PlatformIcon(platform: summary.platform, size: 18)
                    Text(summary.author).font(.headline).lineLimit(1)
                }
                Text(summary.text.isEmpty ? L10n.value("library.mediaOnly") : summary.text)
                    .lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(layoutDirection == .rightToLeft ? .trailing : .leading)
                Text(L10n.format("library.mediaCount", Int64(summary.mediaCount)))
                    .font(.caption).foregroundStyle(StashyTheme.green)
            }
            .frame(maxWidth: .infinity, alignment: layoutDirection == .rightToLeft ? .trailing : .leading)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .task(id: summary.id) {
            guard let manifest = try? await store.loadManifest(id: summary.id),
                  let first = manifest.orderedMedia.min(by: { $0.orderIndex < $1.orderIndex }),
                  let filename = first.localFilename,
                  let url = await store.localMediaURL(archiveID: summary.id, filename: filename)
            else { return }
            lead = LeadMedia(url: url, type: first.type)
        }
    }

    @ViewBuilder private var leadThumbnail: some View {
        if let lead {
            LocalMediaThumbnail(url: lead.url, type: lead.type, cornerRadius: 14)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StashyTheme.hairline)
                .overlay { PlatformIcon(platform: summary.platform, size: 32) }
        }
    }
}

/// One tile in the media grid: a real thumbnail of the saved file with its source badge.
private struct LibraryMediaCell: View {
    let item: ArchivedMediaSummary
    let store: ArchiveStore
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                LocalMediaThumbnail(url: url, type: item.type)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(item.type.tint.opacity(0.16))
                    .overlay { ProgressView() }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            PlatformIcon(platform: item.platform, size: 22).padding(6)
        }
        .accessibilityLabel(Text(L10n.format("media.selection.item", Int64(item.orderIndex + 1), item.type.shortLabel)))
        .accessibilityValue(Text(item.author))
        .task(id: item.id) {
            guard let filename = item.localFilename else { return }
            url = await store.localMediaURL(archiveID: item.archiveID, filename: filename)
        }
    }
}
