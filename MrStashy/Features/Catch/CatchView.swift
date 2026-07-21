import SwiftUI

struct CatchView: View {
    @Environment(AppState.self) private var appState
    @State private var urlText = ""
    @State private var showCapabilities = false

    var body: some View {
        ZStack {
            StashyBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    IllustratedHeader(titleKey: "catch.title", subtitleKey: "catch.subtitle")
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
                Text(String(localized: "catch.recent.empty"))
                    .font(.subheadline)
                    .foregroundStyle(StashyTheme.charcoal.opacity(0.65))
            } else {
                ForEach(appState.libraryPosts.prefix(3)) { item in
                    Label(item.author, systemImage: item.platform == .directMedia ? "link" : "archivebox")
                        .font(.subheadline)
                }
            }
        }
    }
}

private struct ResultReadyRow: View {
    let post: ResolvedPost
    var body: some View {
        HStack(spacing: 12) {
            IllustrationSlot(placement: .results, height: 48).frame(width: 66)
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
