import SwiftUI

struct CatchView: View {
    @Environment(AppState.self) private var appState
    @State private var showCapabilities = false
    @State private var selectedSource: Platform?
    @State private var reviewPost: ResolvedPost?

    /// The address being inspected, and the post already reviewed, both live on `AppState`.
    /// Switching the interface language rebuilds this view from scratch; holding them here meant
    /// a half-typed link was discarded and the already-reviewed marker reset, which pushed the
    /// review screen back on top of a Catch screen the person had just returned to.
    private var urlText: Binding<String> {
        Binding(get: { appState.catchURLText }, set: { appState.catchURLText = $0 })
    }

    var body: some View {
        ZStack {
            StashyBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FeatureHeader(titleKey: "catch.title", subtitleKey: "catch.subtitle")
                    captureForm
                    stateSection
                    recentCatches
                }
                .padding(20)
            }
        }
        .navigationTitle(L10n.value("tab.catch"))
        // The review opens itself the moment a link resolves — no extra tap to see what was
        // found. The card in the ready state stays as a way back in after returning.
        .navigationDestination(item: $reviewPost) { post in
            ResultsView(post: post)
        }
        .onChange(of: readyPost, initial: true) { _, post in
            guard let post, post.id != appState.reviewedPostID else { return }
            appState.reviewedPostID = post.id
            reviewPost = post
        }
        // Draining shared links is the app's job, not this view's. Keying a `.task` on the
        // pending-link count and the busy flag made the resolve cancel itself the moment it
        // started, so every shared link failed while a typed one worked.
        .onAppear { appState.drainPendingLinks() }
        .sheet(isPresented: $showCapabilities) { PlatformDiagnosticsSheet() }
        .sheet(item: $selectedSource) { platform in
            PlatformPasteSheet(platform: platform, urlText: urlText)
        }
    }

    private var readyPost: ResolvedPost? {
        if case .ready(let post) = appState.catchState { return post }
        return nil
    }

    private var captureForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.value("catch.pastePrompt"))
                .font(.headline)
            TextField(L10n.value("catch.urlPlaceholder"), text: urlText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .submitLabel(.go)
                .onSubmit { inspect() }
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StashyTheme.hairline, lineWidth: 1))
                .accessibilityIdentifier("catch.url")
            sourcePicker
            StashyGlassBar {
                // `PasteButton` hands over the clipboard on a deliberate tap, so the person is
                // never shown an unexplained paste-permission alert just for opening a screen.
                PasteButton(payloadType: URL.self) { urls in
                    guard let first = urls.first else { return }
                    Task { @MainActor in appState.catchURLText = first.absoluteString }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(Text(L10n.value("catch.paste")))
                Button { inspect() } label: {
                    Label(L10n.value("catch.resolve"), systemImage: "sparkle.magnifyingglass")
                        // The main action takes the rest of the bar rather than sitting in the
                        // middle of it with a third of the width left empty beside it.
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(appState.catchURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
                .accessibilityIdentifier("catch.resolve")
            }
        }
        .padding(18)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(StashyTheme.hairline, lineWidth: 1))
    }

    private var isResolving: Bool {
        if case .resolving = appState.catchState { return true }
        return false
    }

    private func inspect() {
        let link = appState.catchURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        Task { await appState.resolve(link) }
    }

    /// Every source Stashy can read, all visible at once.
    ///
    /// This was a horizontal strip with hidden scroll indicators. With fourteen sources, ten of
    /// them sat off the right edge with nothing on screen saying they were there — so most of
    /// what the app supports was undiscoverable, and unreachable by anyone who cannot drag.
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.value("catch.sources"))
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 10)], alignment: .leading, spacing: 12) {
                ForEach(PlatformCapabilityRegistry.usable) { capability in
                    Button { selectedSource = capability.platform } label: {
                        VStack(spacing: 5) {
                            PlatformIcon(platform: capability.platform, size: 42, isDecorative: true)
                            Text(L10n.value(capability.platform.titleKey))
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(StashyTheme.ink)
                        }
                        .frame(maxWidth: .infinity, minHeight: 66)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("catch.source.\(capability.platform.rawValue)")
                    .accessibilityLabel(Text(L10n.format(
                        "catch.source.accessibility",
                        L10n.value(capability.platform.titleKey),
                        L10n.value(capability.status.titleKey)
                    )))
                }
            }
        }
    }

    @ViewBuilder private var stateSection: some View {
        switch appState.catchState {
        case .idle:
            Button { showCapabilities = true } label: {
                Label(L10n.value("catch.supportedPlatforms"), systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        case .resolving(let stage):
            HStack(spacing: 12) {
                ProgressView().tint(StashyTheme.greenText)
                Text(L10n.value(stage.titleKey)).font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("catch.resolving")
        case .ready(let post):
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    appState.reviewedPostID = post.id
                    reviewPost = post
                } label: {
                    ResultReadyRow(post: post)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("catch.results")
                // A capture that is not the whole post says so here, so a partial result can
                // never be mistaken for a complete one.
                ForEach(Array(post.warnings.enumerated()), id: \.offset) { _, warning in
                    ResolverWarningRow(text: warning)
                }
                Button {
                    appState.clearCatchResult()
                    appState.catchURLText = ""
                    appState.reviewedPostID = nil
                } label: {
                    Label(L10n.value("catch.startOver"), systemImage: "xmark.circle")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("catch.startOver")
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 12) {
                ContentUnavailableView(
                    L10n.value("catch.failed.title"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
                // Every failure names what to do next, so the screen is never a dead end.
                Text(L10n.value(error.recoveryKey))
                    .font(.footnote)
                    .foregroundStyle(StashyTheme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Button { inspect() } label: {
                        Label(L10n.value("catch.retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        appState.clearCatchResult()
                        appState.catchURLText = ""
                    } label: {
                        Label(L10n.value("catch.startOver"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(.glass)
                }
            }
            .accessibilityIdentifier("catch.failed")
        }
    }

    private var recentCatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.value("catch.recent"))
                .font(.headline)
            if appState.libraryPosts.isEmpty {
                StashyIllustration(name: "stashyCatch", maxHeight: 176)
                    .padding(.top, 4)
                Text(L10n.value("catch.recent.empty"))
                    .font(.subheadline)
                    .foregroundStyle(StashyTheme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                ForEach(appState.libraryPosts.prefix(3)) { item in
                    HStack(spacing: 8) {
                        PlatformIcon(platform: item.platform, size: 24)
                        Text(item.author).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

/// Shown when a capture succeeded but is not the whole post.
struct ResolverWarningRow: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(StashyTheme.ink)
        } icon: {
            Image(systemName: "info.circle.fill").foregroundStyle(StashyTheme.butter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular.tint(StashyTheme.butter.opacity(0.16)), in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("resolver.warning")
    }
}

private struct PlatformPasteSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let platform: Platform
    @Binding var urlText: String
    @State private var draft = ""

    private var capability: PlatformCapability? { PlatformCapabilityRegistry.capability(for: platform) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        PlatformIcon(platform: platform, size: 54, isDecorative: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.value(platform.titleKey)).font(.title3.weight(.bold))
                            Text(L10n.format("catch.sourcePaste.body", L10n.value(platform.titleKey)))
                                .font(.subheadline)
                                .foregroundStyle(StashyTheme.inkSecondary)
                        }
                    }
                    if let capability {
                        // Saying up front what this source can and cannot do keeps the app from
                        // looking broken when a platform simply publishes less than another.
                        VStack(alignment: .leading, spacing: 8) {
                            StatusPill(
                                title: L10n.value(capability.status.titleKey),
                                color: StashyTheme.color(for: capability.status)
                            )
                            Text(capability.evidence)
                                .font(.footnote)
                                .foregroundStyle(StashyTheme.inkSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TextField(L10n.value("catch.urlPlaceholder"), text: $draft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .padding(14)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StashyTheme.hairline, lineWidth: 1))
                    PasteButton(payloadType: URL.self) { urls in
                        guard let first = urls.first else { return }
                        Task { @MainActor in draft = first.absoluteString }
                    }
                    Button {
                        let link = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        urlText = link
                        dismiss()
                        Task { await appState.resolve(link) }
                    } label: {
                        Label(L10n.value("catch.sourcePaste.inspect"), systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
            .navigationTitle(L10n.value("catch.sourcePaste.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.value("action.cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The result card. It shows the actual media the moment a link resolves — a strip of real
/// thumbnails — so a person sees what was found without opening anything, and taps through only
/// to choose and save.
private struct ResultReadyRow: View {
    let post: ResolvedPost
    private var sortedMedia: [ResolvedMedia] { post.media.sorted { $0.orderIndex < $1.orderIndex } }
    private var preview: [ResolvedMedia] { Array(sortedMedia.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PlatformIcon(platform: post.platform, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(L10n.format("catch.ready.count", Int64(post.media.count)))
                        .font(.caption).foregroundStyle(StashyTheme.inkSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").foregroundStyle(StashyTheme.inkSecondary)
            }
            if !preview.isEmpty {
                // Keep the catch preview compact and deterministic. Flexible widths made the
                // last item grow to half the card while portrait/landscape media were loading.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(preview.enumerated()), id: \.element.id) { index, media in
                            RemoteMediaThumbnail(media: media)
                                .frame(width: 88, height: 88)
                                .overlay {
                                    if index == preview.count - 1, sortedMedia.count > preview.count {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.48))
                                            Text(L10n.format("media.more", Int64(sortedMedia.count - preview.count)))
                                                .font(.title3.weight(.bold)).foregroundStyle(.white)
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            if !post.text.isEmpty {
                Text(post.text).font(.caption).foregroundStyle(StashyTheme.ink).lineLimit(2).multilineTextAlignment(.leading)
            }
            Label(L10n.value("catch.ready.reviewSave"), systemImage: "square.and.arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(StashyTheme.greenText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular.tint(StashyTheme.aqua.opacity(0.18)).interactive(), in: .rect(cornerRadius: 22))
    }
}
