import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showDiagnostics = false
    @State private var showResetConfirmation = false
    @State private var showStashImporter = false

    var body: some View {
        ZStack {
            StashyBackground()
            Form {
                Section {
                    IllustratedHeader(titleKey: "settings.title", subtitleKey: "settings.subtitle")
                }
                Section(String(localized: "settings.downloads")) {
                    Picker(String(localized: "settings.quality"), selection: settingBinding(\.quality)) { ForEach(UserSettings.Quality.allCases, id: \.self) { Text(L10n.value("settings.quality.\($0.rawValue)")).tag($0) } }
                    Picker(String(localized: "settings.saveMode"), selection: settingBinding(\.saveMode)) { ForEach(UserSettings.SaveMode.allCases, id: \.self) { Text(L10n.value("settings.saveMode.\($0.rawValue)")).tag($0) } }
                    Toggle(String(localized: "settings.photos"), isOn: settingBinding(\.saveToPhotos))
                    Toggle(String(localized: "settings.cellular"), isOn: settingBinding(\.allowCellular))
                    Stepper(L10n.format("settings.parallel", Int64(appState.settings.maxParallelDownloads)), value: settingBinding(\.maxParallelDownloads), in: 1 ... 5)
                }
                Section(String(localized: "settings.appearance")) {
                    Picker(String(localized: "settings.appearance"), selection: settingBinding(\.appearance)) { ForEach(UserSettings.Appearance.allCases, id: \.self) { Text(L10n.value("settings.appearance.\($0.rawValue)")).tag($0) } }
                    Toggle(String(localized: "settings.reduceMotion"), isOn: settingBinding(\.reduceMotion))
                }
                Section(String(localized: "settings.privacy")) {
                    Text(String(localized: "settings.privacy.body"))
                    Button(String(localized: "settings.platformDiagnostics")) { showDiagnostics = true }
                    Button(String(localized: "settings.resetOnboarding"), role: .destructive) { showResetConfirmation = true }
                }
                Section(String(localized: "settings.library")) {
                    Button { showStashImporter = true } label: {
                        Label(String(localized: "settings.importStash"), systemImage: "square.and.arrow.down")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(String(localized: "tab.settings"))
        .sheet(isPresented: $showDiagnostics) { PlatformDiagnosticsSheet() }
        .confirmationDialog(String(localized: "settings.resetOnboarding"), isPresented: $showResetConfirmation) {
            Button(String(localized: "action.reset"), role: .destructive) { appState.onboardingComplete = false; UserDefaults.standard.set(false, forKey: "onboarding.complete") }
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
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
    }
}

struct PlatformDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(PlatformCapabilityRegistry.all) { capability in
                HStack {
                    VStack(alignment: .leading) {
                        Text(L10n.value(capability.platform.titleKey)).font(.headline)
                        Text(capability.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(title: L10n.value("support.\(capability.status.rawValue)"), color: capability.status == .passing ? StashyTheme.green : StashyTheme.pink)
                }
            }
            .navigationTitle(String(localized: "settings.platformDiagnostics"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "action.done")) { dismiss() } } }
        }
    }
}
