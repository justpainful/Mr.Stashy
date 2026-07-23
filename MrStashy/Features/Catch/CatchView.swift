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
        .navigationTitle(String(localized: "tab.catch"))
        .onAppear {
            if let pending = appState.pendingLink { urlText = pending.absoluteString; appState.pendingLink = nil }
        }
        .sheet(isPresented: $showCapabilities) { PlatformDiagnosticsSheet() }
        .sheet(item: $selectedSource) { platform in
            PlatformPasteSheet(platform: platform, urlText: $urlText)
        }
    }

    private var captureForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "catch.pastePrompt"))
                .font(.headline)
            TextField(String(localized: "catch.urlPlaceholder"), text: $urlText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StashyTheme.charcoal.opacity(0.2), lineWidth: 1))
                .accessibilityIdentifier("catch.url")
            sourcePicker
            StashyGlassBar {
                Button {
                    Task { @MainActor in
                        if let clipboard = UIPasteboard.general.string { urlText = clipboard }
                    }
                } label: { Label(String(localized: "catch.paste"), systemImage: "doc.on.clipboard") }
                .buttonStyle(.glass)
                Button {
                    Task { await appState.resolve(urlText) }
                } label: { Label(String(localized: "catch.resolve"), systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(.glassProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("catch.resolve")
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(StashyTheme.charcoal.opacity(0.14), lineWidth: 1))
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "catch.sources"))
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Platform.quickCapturePlatforms) { platform in
                        Button { selectedSource = platform } label: {
                            VStack(spacing: 5) {
                                PlatformIcon(platform: platform, size: 42)
                                Text(L10n.value(platform.titleKey))
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(width: 54)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("catch.source.\(platform.rawValue)")
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
                Label(String(localized: "catch.supportedPlatforms"), systemImage: "checkmark.shield")
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
            NavigationLink {
                ResultsView(post: post)
            } label: {
                ResultReadyRow(post: post)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("catch.results")
        case .failed(let error):
            ContentUnavailableView(String(localized: "catch.failed.title"), systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
        }
    }

    private var recentCatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "catch.recent"))
                .font(.headline)
            if appState.libraryPosts.isEmpty {
                StashyIllustration(name: "stashyCatch", maxHeight: 176)
                    .padding(.top, 4)
                Text(String(localized: "catch.recent.empty"))
                    .font(.subheadline)
                    .foregroundStyle(StashyTheme.charcoal.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(appState.libraryPosts.prefix(3)) { item in
                    HStack(spacing: 8) {
                        PlatformIcon(platform: item.platform, size: 24)
                        Text(item.author)
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

private struct PlatformPasteSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let platform: Platform
    @Binding var urlText: String
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    PlatformIcon(platform: platform, size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.value(platform.titleKey)).font(.title3.weight(.bold))
                        Text(L10n.format("catch.sourcePaste.body", L10n.value(platform.titleKey)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField(String(localized: "catch.urlPlaceholder"), text: $draft, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(StashyTheme.charcoal.opacity(0.2), lineWidth: 1))
                Button { pasteClipboard() } label: {
                    Label(String(localized: "catch.sourcePaste.clipboard"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                Spacer()
                Button {
                    let link = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    urlText = link
                    dismiss()
                    Task { await appState.resolve(link) }
                } label: {
                    Label(String(localized: "catch.sourcePaste.inspect"), systemImage: "sparkle.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
            .navigationTitle(String(localized: "catch.sourcePaste.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
            }
            .task { pasteClipboard() }
        }
        .presentationDetents([.medium])
    }

    private func pasteClipboard() {
        if let url = UIPasteboard.general.url {
            draft = url.absoluteString
        } else if let text = UIPasteboard.general.string {
            draft = text
        }
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
                Text(String(localized: "catch.ready.title")).font(.headline)
                Text(L10n.format("catch.ready.count", Int64(post.media.count)))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
        }
        .padding(16)
        .glassEffect(.regular.tint(StashyTheme.aqua.opacity(0.18)).interactive(), in: .rect(cornerRadius: 20))
    }
}
