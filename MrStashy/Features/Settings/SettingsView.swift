import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showDiagnostics = false
    @State private var showResetConfirmation = false
    @State private var showStashImporter = false
    @State private var showDeleteLibraryConfirmation = false
    @State private var storageBytes: Int64 = 0

    var body: some View {
        ZStack {
            StashyBackground()
            Form {
                Section {
                    FeatureHeader(titleKey: "settings.title", subtitleKey: "settings.subtitle")
                }
                Section(L10n.value("settings.downloads")) {
                    Picker(L10n.value("settings.quality"), selection: settingBinding(\.quality)) { ForEach(UserSettings.Quality.allCases, id: \.self) { Text(L10n.value("settings.quality.\($0.rawValue)")).tag($0) } }
                    Picker(L10n.value("settings.saveMode"), selection: settingBinding(\.saveMode)) { ForEach(UserSettings.SaveMode.allCases, id: \.self) { Text(L10n.value("settings.saveMode.\($0.rawValue)")).tag($0) } }
                    Toggle(L10n.value("settings.photos"), isOn: settingBinding(\.saveToPhotos))
                    Toggle(L10n.value("settings.cellular"), isOn: settingBinding(\.allowCellular))
                    Stepper(L10n.format("settings.parallel", Int64(appState.settings.maxParallelDownloads)), value: settingBinding(\.maxParallelDownloads), in: 1 ... 5)
                }
                Section(L10n.value("settings.appearance")) {
                    Picker(L10n.value("settings.appearance"), selection: settingBinding(\.appearance)) { ForEach(UserSettings.Appearance.allCases, id: \.self) { Text(L10n.value("settings.appearance.\($0.rawValue)")).tag($0) } }
                    Picker(L10n.value("settings.theme"), selection: settingBinding(\.theme)) { ForEach(UserSettings.Theme.allCases, id: \.self) { Text(L10n.value("settings.theme.\($0.rawValue)")).tag($0) } }
                    Picker(L10n.value("settings.language"), selection: settingBinding(\.language)) { ForEach(UserSettings.AppLanguage.allCases, id: \.self) { Text(L10n.value("settings.language.\($0.rawValue)")).tag($0) } }
                    Toggle(L10n.value("settings.reduceMotion"), isOn: settingBinding(\.reduceMotion))
                }
                Section(L10n.value("settings.sources")) {
                    Button(L10n.value("settings.platformDiagnostics")) { showDiagnostics = true }
                        .accessibilityIdentifier("settings.platformDiagnostics")
                    NavigationLink(L10n.value("settings.credentials")) { ResolverCredentialsView() }
                }
                Section(L10n.value("settings.privacy")) {
                    Text(L10n.value("settings.privacy.body"))
                    Button(L10n.value("settings.resetOnboarding"), role: .destructive) { showResetConfirmation = true }
                }
                Section(L10n.value("settings.library")) {
                    LabeledContent(L10n.value("settings.storageUsed")) {
                        Text(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                    }
                    Button { showStashImporter = true } label: {
                        Label(L10n.value("settings.importStash"), systemImage: "square.and.arrow.down")
                    }
                    Button(role: .destructive) { showDeleteLibraryConfirmation = true } label: {
                        Label(L10n.value("settings.deleteLibrary"), systemImage: "trash")
                    }
                }
                Section(L10n.value("settings.about")) {
                    LabeledContent(L10n.value("settings.version"), value: versionDescription)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L10n.value("tab.settings"))
        .task { storageBytes = await appState.archiveStore.storageUsageBytes() }
        .sheet(isPresented: $showDiagnostics) { PlatformDiagnosticsSheet() }
        .confirmationDialog(L10n.value("settings.resetOnboarding"), isPresented: $showResetConfirmation) {
            Button(L10n.value("action.reset"), role: .destructive) { appState.onboardingComplete = false; UserDefaults.standard.set(false, forKey: "onboarding.complete") }
        }
        .confirmationDialog(L10n.value("settings.deleteLibrary.title"), isPresented: $showDeleteLibraryConfirmation) {
            Button(L10n.value("settings.deleteLibrary.confirm"), role: .destructive) {
                Task { await deleteLibrary() }
            }
            Button(L10n.value("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.value("settings.deleteLibrary.message"))
        }
        .fileImporter(isPresented: $showStashImporter, allowedContentTypes: [UTType(filenameExtension: "stash") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            Task { await importStash(from: url) }
        }
    }

    private func settingBinding<T>(_ keyPath: WritableKeyPath<UserSettings, T>) -> Binding<T> {
        Binding(get: { appState.settings[keyPath: keyPath] }, set: { value in appState.settings[keyPath: keyPath] = value; appState.settings.save() })
    }

    private func importStash(from url: URL) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await appState.archiveStore.importStash(from: url)
            appState.libraryPosts = await appState.archiveStore.loadSummaries()
            storageBytes = await appState.archiveStore.storageUsageBytes()
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func deleteLibrary() async {
        do {
            try await appState.archiveStore.deleteAllArchives()
            appState.libraryPosts = []
            storageBytes = await appState.archiveStore.storageUsageBytes()
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
    }
}

struct PlatformDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.value("settings.platformDiagnostics.body"))
                        .font(.footnote)
                        .foregroundStyle(StashyTheme.inkSecondary)
                }
                ForEach(SupportStatus.allCases, id: \.self) { status in
                    let group = PlatformCapabilityRegistry.all.filter { $0.status == status }
                    if !group.isEmpty {
                        Section(L10n.value(status.titleKey)) {
                            ForEach(group) { capability in
                                CapabilityRow(capability: capability)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.value("settings.platformDiagnostics"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.value("action.done")) { dismiss() } } }
        }
    }
}

private struct CapabilityRow: View {
    let capability: PlatformCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PlatformIcon(platform: capability.platform, size: 30)
                Text(L10n.value(capability.platform.titleKey)).font(.headline)
                Spacer()
                StatusPill(
                    title: L10n.value(capability.status.titleKey),
                    color: StashyTheme.color(for: capability.status)
                )
            }
            Text(capability.evidence)
                .font(.caption)
                .foregroundStyle(StashyTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let credential = capability.unlockCredential {
                Label(L10n.format("settings.credentials.unlocks", L10n.value(credential.titleKey)), systemImage: "key")
                    .font(.caption2)
                    .foregroundStyle(StashyTheme.inkSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diagnostics.\(capability.platform.rawValue)")
    }
}

/// Lets the owner of a developer account supply their own key so a source that publishes more
/// to an authorized reader can be captured in full. Values go straight to the Keychain and are
/// never written to settings, manifests, archives, diagnostics, or logs.
struct ResolverCredentialsView: View {
    @Environment(AppState.self) private var appState
    @State private var drafts: [ResolverCredential: String] = [:]
    @State private var stored: Set<ResolverCredential> = []

    var body: some View {
        Form {
            Section {
                Text(L10n.value("settings.credentials.body"))
                    .font(.footnote)
                    .foregroundStyle(StashyTheme.inkSecondary)
            }
            ForEach(ResolverCredential.allCases, id: \.self) { credential in
                Section(L10n.value(credential.titleKey)) {
                    Text(L10n.value(credential.helpKey))
                        .font(.caption)
                        .foregroundStyle(StashyTheme.inkSecondary)
                    SecureField(
                        L10n.value("settings.credentials.placeholder"),
                        text: Binding(
                            get: { drafts[credential] ?? "" },
                            set: { drafts[credential] = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    HStack {
                        Button(L10n.value("settings.credentials.save")) { save(credential) }
                            .disabled((drafts[credential] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if stored.contains(credential) {
                            Button(L10n.value("settings.credentials.remove"), role: .destructive) { remove(credential) }
                        }
                    }
                    if stored.contains(credential) {
                        Label(L10n.value("settings.credentials.stored"), systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(StashyTheme.green)
                    }
                }
            }
        }
        .navigationTitle(L10n.value("settings.credentials"))
        .task { refreshStored() }
    }

    private func refreshStored() {
        stored = Set(ResolverCredential.allCases.filter { KeychainStore.resolverCredential(for: $0) != nil })
    }

    private func save(_ credential: ResolverCredential) {
        do {
            try KeychainStore.saveResolverCredential(drafts[credential] ?? "", for: credential)
            drafts[credential] = ""
            refreshStored()
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
    }

    private func remove(_ credential: ResolverCredential) {
        KeychainStore.deleteResolverCredential(for: credential)
        refreshStored()
    }
}
