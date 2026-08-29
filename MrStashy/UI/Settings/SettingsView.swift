import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingCredential: Credential?
    @State private var confirmDeleteAll = false
    @State private var credentialPresence: [Credential: Bool] = [:]

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section(L10n.value("settings.saving")) {
                    Picker(L10n.value("catch.quality"), selection: $model.settings.quality) {
                        ForEach(QualityPreference.allCases, id: \.self) { Text(L10n.value($0.titleKey)).tag($0) }
                    }
                    Toggle(L10n.value("catch.toPhotos"), isOn: $model.settings.saveToPhotos)
                    Toggle(L10n.value("settings.cellular"), isOn: $model.settings.allowCellular)
                    Stepper(value: $model.settings.parallelDownloads, in: 1 ... 4) {
                        HStack {
                            Text(L10n.value("settings.parallel"))
                            Spacer()
                            Text("\(model.settings.parallelDownloads)").monospacedDigit().foregroundStyle(Theme.muted)
                        }
                    }
                }

                Section(L10n.value("settings.appearance")) {
                    Picker(L10n.value("settings.appearance"), selection: $model.settings.appearance) {
                        ForEach(Settings.Appearance.allCases, id: \.self) { Text(L10n.value("settings.appearance.\($0.rawValue)")).tag($0) }
                    }
                    Picker(L10n.value("settings.language"), selection: $model.settings.language) {
                        ForEach(Settings.Language.allCases, id: \.self) { Text(L10n.value("settings.language.\($0.rawValue)")).tag($0) }
                    }
                }

                Section {
                    ForEach(Credential.allCases, id: \.self) { credential in
                        Button {
                            editingCredential = credential
                        } label: {
                            HStack {
                                Text(L10n.value(credential.titleKey)).foregroundStyle(Theme.ink)
                                Spacer()
                                Text(credentialPresence[credential] == true ? L10n.value("settings.keySet") : L10n.value("settings.keyMissing"))
                                    .font(.subheadline)
                                    .foregroundStyle(credentialPresence[credential] == true ? Theme.verified : Theme.muted)
                            }
                        }
                        .accessibilityIdentifier("settings.credential.\(credential.rawValue)")
                    }
                } header: {
                    Text(L10n.value("settings.keys"))
                } footer: {
                    Text(L10n.value("settings.keysFooter"))
                }

                Section(L10n.value("settings.sources")) {
                    NavigationLink(L10n.value("settings.sourcesDetail")) { SourceCapabilityView() }
                }

                Section {
                    HStack {
                        Text(L10n.value("settings.storageUsed"))
                        Spacer()
                        Text(L10n.byteCount(model.storageBytes)).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                    HStack {
                        Text(L10n.value("settings.archives"))
                        Spacer()
                        Text("\(model.library.count)").monospacedDigit().foregroundStyle(Theme.muted)
                    }
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Text(L10n.value("settings.deleteAll"))
                    }
                    .disabled(model.library.isEmpty)
                } header: {
                    Text(L10n.value("settings.storage"))
                }

                Section {
                    Text(L10n.value("settings.privacy"))
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    HStack {
                        Text(L10n.value("settings.version"))
                        Spacer()
                        Text(Self.version).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text(L10n.value("settings.about"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationTitle(L10n.value("tab.settings"))
            .sheet(item: $editingCredential) { credential in
                CredentialEditor(credential: credential) { refreshPresence() }
            }
            .confirmationDialog(L10n.value("settings.deleteAllConfirm"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button(L10n.value("settings.deleteAll"), role: .destructive) { Task { await model.deleteAllArchives() } }
            }
            .onAppear { refreshPresence() }
        }
    }

    private func refreshPresence() {
        for credential in Credential.allCases { credentialPresence[credential] = Keychain.has(credential) }
    }

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

extension Credential: Identifiable {
    var id: String { rawValue }
}

struct CredentialEditor: View {
    var credential: Credential
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L10n.value("settings.keyValue"), text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.keyField")
                } footer: {
                    Text(L10n.value(credential.helpKey))
                }
                if failed {
                    Text(L10n.value("settings.keyInvalid")).foregroundStyle(Theme.warn)
                }
                if Keychain.has(credential) {
                    Button(role: .destructive) {
                        Keychain.delete(credential)
                        onChange()
                        dismiss()
                    } label: {
                        Text(L10n.value("settings.keyRemove"))
                    }
                }
            }
            .navigationTitle(L10n.value(credential.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.value("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.value("common.save")) {
                        do {
                            try Keychain.save(value, for: credential)
                            onChange()
                            dismiss()
                        } catch {
                            failed = true
                        }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// What each source gives, stated plainly. The sentences are localisation keys so the
/// Arabic screen is Arabic all the way down.
struct SourceCapabilityView: View {
    var body: some View {
        List {
            ForEach(Platform.featured + [.web]) { platform in
                HStack(alignment: .top, spacing: 12) {
                    PlatformGlyph(platform: platform, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.value(platform.titleKey)).font(.headline).foregroundStyle(Theme.ink)
                        Text(L10n.value("source.\(platform.rawValue)")).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("sources.\(platform.rawValue)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle(L10n.value("settings.sources"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
