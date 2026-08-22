import SwiftUI

struct CatchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inputCard
                    switch model.catchState {
                    case .idle:
                        sourcesCard
                        recentSaves
                    case .working(let message):
                        WorkingCard(message: message)
                    case .failed(let error):
                        FailureCard(error: error) { model.resolve() }
                    case .ready(let post):
                        PostPreview(post: post)
                    }
                }
                .padding(16)
            }
            .background(Theme.paper)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.value("tab.catch"))
            .toolbar {
                if model.catchState != .idle {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.value("common.clear")) { model.clearCatch() }
                            .accessibilityIdentifier("catch.clear")
                    }
                }
            }
        }
    }

    private var inputCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(Theme.muted)
                TextField(L10n.value("catch.placeholder"), text: $model.linkInput, axis: .vertical)
                    .lineLimit(1 ... 3)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($inputFocused)
                    .onSubmit { model.resolve() }
                    .accessibilityIdentifier("catch.input")
                if !model.linkInput.isEmpty {
                    Button {
                        model.linkInput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .accessibilityLabel(L10n.value("common.clear"))
                }
            }
            .padding(14)
            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 10) {
                Button {
                    model.pasteFromClipboard()
                } label: {
                    Label(L10n.value("catch.paste"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("catch.paste")
                Button {
                    inputFocused = false
                    model.resolve()
                } label: {
                    Label(L10n.value("catch.go"), systemImage: "arrow.down.to.line")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.linkInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("catch.go")
            }
        }
        .padding(14)
        .card()
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.value("catch.sources"))
                .font(.headline)
                .foregroundStyle(Theme.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(Platform.featured) { platform in
                    HStack(spacing: 8) {
                        PlatformGlyph(platform: platform, size: 24)
                        Text(L10n.value(platform.titleKey))
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("catch.source.\(platform.rawValue)")
                }
            }
            Text(L10n.value("catch.sourcesNote"))
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .padding(14)
        .card()
    }

    @ViewBuilder private var recentSaves: some View {
        if !model.library.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.value("catch.recent"))
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button(L10n.value("catch.seeLibrary")) { model.selectedTab = .library }
                        .font(.subheadline)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.library.prefix(10)) { summary in
                            NavigationLink(value: summary.id) {
                                ArchiveTile(summary: summary, width: 120)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .card()
            .navigationDestination(for: UUID.self) { id in
                ArchiveDetailView(archiveID: id)
            }
        }
    }
}

private struct WorkingCard: View {
    var message: String

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.ink)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityIdentifier("catch.working")
    }
}

private struct FailureCard: View {
    var error: StashyError
    var retry: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.errorDescription ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.warn)
            Text(error.recovery)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            HStack {
                Button(L10n.value("common.retry"), action: retry)
                    .buttonStyle(SecondaryButtonStyle())
                if error == .loginRequired {
                    Button(L10n.value("catch.openSettings")) { model.selectedTab = .settings }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(16)
        .card()
        .accessibilityIdentifier("catch.failure")
    }
}

// MARK: - Preview of a resolved post

struct PostPreview: View {
    var post: Post
    @Environment(AppModel.self) private var model
    @State private var selected: Set<UUID> = []
    @State private var quality: QualityPreference = .best
    @State private var toPhotos = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !post.text.isEmpty || post.title != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let title = post.title, !title.isEmpty {
                        Text(title).font(.headline).foregroundStyle(Theme.ink)
                    }
                    if !post.text.isEmpty {
                        Text(post.text)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(6)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            ForEach(post.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            itemsCard
            optionsCard
            Button {
                model.enqueue(post, selected: selected, quality: quality, toPhotos: toPhotos)
            } label: {
                Text(L10n.plural("catch.save", selected.count))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selected.isEmpty)
            .accessibilityIdentifier("catch.saveButton")
        }
        .onAppear {
            selected = Set(post.items.map(\.id))
            quality = model.settings.quality
            toPhotos = model.settings.saveToPhotos
        }
        .accessibilityIdentifier("catch.preview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            PlatformGlyph(platform: post.platform, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.author.display.isEmpty ? L10n.value(post.platform.titleKey) : post.author.display)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let handle = post.author.handle, !post.author.name.isEmpty {
                        Text("@\(handle)").lineLimit(1)
                    }
                    if let date = post.createdAt {
                        Text(L10n.date(date, time: .omitted))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(14)
        .card()
    }

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.plural("catch.items", post.items.count))
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button(selected.count == post.items.count ? L10n.value("catch.selectNone") : L10n.value("catch.selectAll")) {
                    selected = selected.count == post.items.count ? [] : Set(post.items.map(\.id))
                }
                .font(.subheadline)
            }
            .padding(14)
            Divider().overlay(Theme.rule)
            ForEach(post.items) { item in
                MediaItemRow(item: item, quality: quality, isSelected: selected.contains(item.id)) {
                    if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                }
                .accessibilityIdentifier("catch.item.\(item.index)")
                if item.id != post.items.last?.id { Divider().overlay(Theme.rule).padding(.leading, 96) }
            }
        }
        .card()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.value("catch.quality"))
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Picker(L10n.value("catch.quality"), selection: $quality) {
                ForEach(QualityPreference.allCases, id: \.self) { preference in
                    Text(L10n.value(preference.titleKey)).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $toPhotos) {
                Label(L10n.value("catch.toPhotos"), systemImage: "photo.on.rectangle.angled")
                    .foregroundStyle(Theme.ink)
            }
            .tint(Theme.amber)
            .accessibilityIdentifier("catch.toPhotos")
        }
        .padding(14)
        .card()
    }
}

struct MediaItemRow: View {
    var item: MediaItem
    var quality: QualityPreference
    var isSelected: Bool
    var toggle: () -> Void

    private var chosen: MediaVariant? { SaveEngine.candidates(for: item, preference: quality).first }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteThumbnail(url: item.thumbnailURL)
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if item.kind == .video || item.kind == .gif {
                        Image(systemName: item.kind == .video ? "play.fill" : "photo.stack.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: item.kind.systemImage)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Text(L10n.value(item.kind.titleKey))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        if let duration = Format.duration(item.duration) {
                            Text(L10n.isolated(duration))
                                .font(.subheadline)
                                .foregroundStyle(Theme.muted)
                                .monospacedDigit()
                        }
                    }
                    if let chosen {
                        SpecLine([chosen.resolutionLabel, chosen.codec, Format.bytes(chosen.sizeBytes)])
                        if item.variants.count > 1 {
                            Text(L10n.plural("catch.variants", item.variants.count))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.amber : Theme.muted)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
