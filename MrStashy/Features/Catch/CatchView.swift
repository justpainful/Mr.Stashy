import SwiftUI

struct CatchView: View {
    @Environment(AppState.self) private var appState
    @State private var urlText = ""
    @State private var showCapabilities = false
    @State private var selectedSource: Platform?

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
        // A link shared from another app can arrive while this screen is already visible, so it
        // is consumed whenever the shared list changes, not only when the view first appears.
        .task(id: appState.pendingLinks) { consumeSharedLink() }
        .sheet(isPresented: $showCapabilities) { PlatformDiagnosticsSheet() }
        .sheet(item: $selectedSource) { platform in
            PlatformPasteSheet(platform: platform, urlText: $urlText)
        }
    }

    private func consumeSharedLink() {
        guard let link = appState.takeNextPendingLink() else { return }
        urlText = link.absoluteString
        Task { await appState.resolve(link.absoluteString) }
    }

    private var captureForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.value("catch.pastePrompt"))
                .font(.headline)
            TextField(L10n.value("catch.urlPlaceholder"), text: $urlText, axis: .vertical)
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
                    Task { @MainActor in urlText = first.absoluteString }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(Text(L10n.value("catch.paste")))
                Button { inspect() } label: {
                    Label(L10n.value("catch.resolve"), systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.glassProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
                .accessibilityIdentifier("catch.resolve")
                Spacer(minLength: 0)
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
        let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        Task { await appState.resolve(link) }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.value("catch.sources"))
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(PlatformCapabilityRegistry.usable) { capability in
                        Button { selectedSource = capability.platform } label: {
                            VStack(spacing: 5) {
                                PlatformIcon(platform: capability.platform, size: 42)
                                Text(L10n.value(capability.platform.titleKey))
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .foregroundStyle(StashyTheme.ink)
                            }
                            .frame(width: 58)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("catch.source.\(capability.platform.rawValue)")
                        .accessibilityLabel(Text(L10n.format(
                            "catch.source.accessibility",
                            L10n.value(capability.platform.titleKey),
                            L10n.value(capability.status.titleKey)
                        )))
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
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
                ProgressView().tint(StashyTheme.green)
                Text(L10n.value(stage.titleKey)).font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("catch.resolving")
        case .ready(let post):
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink {
                    ResultsView(post: post)
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
                        urlText = ""
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
                        PlatformIcon(platform: platform, size: 54)
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

private struct ResultReadyRow: View {
    let post: ResolvedPost
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(StashyTheme.green)
                .frame(width: 66, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(L10n.value("catch.ready.title")).font(.headline)
                Text(L10n.format("catch.ready.count", Int64(post.media.count)))
                    .font(.subheadline).foregroundStyle(StashyTheme.inkSecondary)
            }
            Spacer()
            // A forward chevron follows the reading direction, so it points correctly in Arabic.
            Image(systemName: "chevron.forward")
        }
        .padding(16)
        .glassEffect(.regular.tint(StashyTheme.aqua.opacity(0.18)).interactive(), in: .rect(cornerRadius: 20))
    }
}
