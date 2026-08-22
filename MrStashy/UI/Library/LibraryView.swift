import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var importing = false

    enum Filter: Hashable {
        case all, videos, photos, pinned, collection(UUID)
    }

    private var filtered: [ArchiveSummary] {
        let pinnedFirst = model.library.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.savedAt > rhs.savedAt
        }
        switch filter {
        case .all: return pinnedFirst
        case .videos: return pinnedFirst.filter { $0.videoCount > 0 }
        case .photos: return pinnedFirst.filter { $0.photoCount > 0 }
        case .pinned: return pinnedFirst.filter(\.isPinned)
        case .collection(let id): return pinnedFirst.filter { $0.collectionIDs.contains(id) }
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    filters
                    if filtered.isEmpty {
                        EmptyNotice(
                            symbol: "archivebox",
                            text: model.library.isEmpty ? L10n.value("library.empty") : L10n.value("library.emptyFilter"),
                            action: model.library.isEmpty ? (L10n.value("library.goCatch"), { model.selectedTab = .catchTab }) : nil
                        )
                        .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { summary in
                                NavigationLink(value: summary.id) {
                                    ArchiveTile(summary: summary)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { ArchiveActions(summary: summary) }
                                .accessibilityIdentifier("library.archive.\(summary.id.uuidString)")
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.paper)
            .navigationTitle(L10n.value("tab.library"))
            .searchable(text: $model.librarySearch, prompt: L10n.value("library.search"))
            .navigationDestination(for: UUID.self) { id in ArchiveDetailView(archiveID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showNewCollection = true
                        } label: {
                            Label(L10n.value("library.newCollection"), systemImage: "folder.badge.plus")
                        }
                        Button {
                            importing = true
                        } label: {
                            Label(L10n.value("library.import"), systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("library.menu")
                }
            }
            .alert(L10n.value("library.newCollection"), isPresented: $showNewCollection) {
                TextField(L10n.value("library.collectionName"), text: $newCollectionName)
                Button(L10n.value("common.create")) {
                    let name = newCollectionName
                    newCollectionName = ""
                    Task { await model.createCollection(name) }
                }
                Button(L10n.value("common.cancel"), role: .cancel) { newCollectionName = "" }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .data]) { result in
                if case .success(let url) = result { Task { await model.importPackage(url) } }
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: L10n.value("library.filter.all"), isOn: filter == .all) { filter = .all }
                FilterChip(title: L10n.value("library.filter.videos"), isOn: filter == .videos) { filter = .videos }
                FilterChip(title: L10n.value("library.filter.photos"), isOn: filter == .photos) { filter = .photos }
                FilterChip(title: L10n.value("library.filter.pinned"), isOn: filter == .pinned) { filter = .pinned }
                ForEach(model.collections) { collection in
                    FilterChip(title: collection.name, isOn: filter == .collection(collection.id)) { filter = .collection(collection.id) }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await model.deleteCollection(collection.id) }
                                if filter == .collection(collection.id) { filter = .all }
                            } label: {
                                Label(L10n.value("library.deleteCollection"), systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
}

struct FilterChip: View {
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isOn ? Theme.amber : Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.rule, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct ArchiveTile: View {
    var summary: ArchiveSummary
    var width: CGFloat?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                cover
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 4) {
                    PlatformGlyph(platform: summary.platform, size: 22)
                    if summary.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Theme.amber, in: Circle())
                    }
                }
                .padding(6)
                if summary.fileCount > 1 {
                    Text("\(summary.fileCount)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if summary.videoCount > 0 {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Text(summary.headline)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            SpecLine([summary.authorName, Format.bytes(summary.totalBytes)], verified: true)
                .frame(width: width, alignment: .leading)
        }
    }

    @ViewBuilder private var cover: some View {
        if let filename = summary.coverFilename {
            LocalImage(url: model.store.archivesDirectoryURL(folder: summary.folder).appendingPathComponent(filename))
        } else {
            ZStack {
                Theme.cardRaised
                Image(systemName: summary.coverKind == .audio ? "waveform" : "doc")
                    .font(.title)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

extension ArchiveStore {
    /// Path arithmetic only; safe to call from any context.
    nonisolated func archivesDirectoryURL(folder: String) -> URL {
        root.appendingPathComponent("Archives", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
    }
}

/// The actions every archive offers, shared by the context menu and the detail toolbar.
struct ArchiveActions: View {
    var summary: ArchiveSummary
    var afterDelete: (() -> Void)?
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?

    var body: some View {
        Button {
            Task { await model.togglePin(summary.id) }
        } label: {
            Label(summary.isPinned ? L10n.value("library.unpin") : L10n.value("library.pin"), systemImage: summary.isPinned ? "pin.slash" : "pin")
        }
        if !model.collections.isEmpty {
            Menu {
                ForEach(model.collections) { collection in
                    Button {
                        Task { await model.toggleMembership(archive: summary.id, collection: collection.id) }
                    } label: {
                        if summary.collectionIDs.contains(collection.id) {
                            Label(collection.name, systemImage: "checkmark")
                        } else {
                            Text(collection.name)
                        }
                    }
                }
            } label: {
                Label(L10n.value("library.collections"), systemImage: "folder")
            }
        }
        Button {
            Task { await model.saveToPhotos(archive: summary.id) }
        } label: {
            Label(L10n.value("library.saveToPhotos"), systemImage: "photo.on.rectangle.angled")
        }
        Button {
            Task {
                if let url = await model.exportArchive(summary.id) { ShareSheet.present(url) }
            }
        } label: {
            Label(L10n.value("library.export"), systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
            Task {
                await model.delete(summary.id)
                afterDelete?()
            }
        } label: {
            Label(L10n.value("common.delete"), systemImage: "trash")
        }
    }
}

/// Presents the system share sheet from wherever the app is, without threading a binding
/// through every context menu.
enum ShareSheet {
    @MainActor static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.keyWindow?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = controller.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        controller.present(sheet, animated: true)
    }

    @MainActor static func present(_ url: URL) { present([url]) }
}
