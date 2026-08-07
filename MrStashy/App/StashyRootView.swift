import SwiftUI

struct StashyRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        Group {
            if appState.onboardingComplete {
                appShell
            } else {
                OnboardingView(onComplete: appState.completeOnboarding)
            }
        }
        .tint(StashyTheme.accent(for: appState.settings.theme))
        .preferredColorScheme(appState.settings.appearance.colorScheme)
        .environment(\.locale, appState.settings.language.locale)
        // Arabic has to lay out right-to-left even when the device itself is left-to-right.
        // Without this, choosing Arabic translated the words and left the layout mirrored wrong.
        .environment(\.layoutDirection, appState.settings.language.layoutDirection ?? UserSettings.AppLanguage.systemLayoutDirection)
        .transaction { transaction in
            if systemReduceMotion || appState.settings.reduceMotion { transaction.animation = nil }
        }
        .onOpenURL(perform: appState.handleOpenURL)
        // Text is read through `L10n`, which is not observable, so changing the language has to
        // rebuild the tree rather than rely on a value dependency that does not exist.
        .id(appState.settings.language)
        .alert(
            L10n.value("error.title"),
            isPresented: Binding(get: { appState.lastError != nil }, set: { if !$0 { appState.lastError = nil } })
        ) {
            Button(L10n.value("action.done")) { appState.lastError = nil }
        } message: {
            Text(appState.lastError?.message ?? "")
        }
        .alert(
            L10n.value("notice.title"),
            isPresented: Binding(get: { appState.lastNotice != nil }, set: { if !$0 { appState.lastNotice = nil } })
        ) {
            Button(L10n.value("action.done")) { appState.lastNotice = nil }
        } message: {
            Text(appState.lastNotice?.message ?? "")
        }
    }

    private var appShell: some View {
        TabView(selection: Binding(get: { appState.selectedTab }, set: { appState.selectedTab = $0 })) {
            NavigationStack { CatchView() }
                .tabItem { Label(L10n.value(AppTab.catch.titleKey), systemImage: AppTab.catch.systemImage) }
                .tag(AppTab.catch)
            NavigationStack { LibraryView() }
                .tabItem { Label(L10n.value(AppTab.library.titleKey), systemImage: AppTab.library.systemImage) }
                .tag(AppTab.library)
            NavigationStack { QueueView() }
                .tabItem { Label(L10n.value(AppTab.queue.titleKey), systemImage: AppTab.queue.systemImage) }
                .tag(AppTab.queue)
                .badge(appState.activeQueueBadge)
            NavigationStack { SettingsView() }
                .tabItem { Label(L10n.value(AppTab.settings.titleKey), systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
    }
}

extension AppState {
    /// How many transfers are still running, so a background save stays visible without
    /// pulling the person away from the screen they are on.
    var activeQueueBadge: Int {
        queueItems.filter { !$0.stage.isFinished }.count
    }
}

extension UserSettings.AppLanguage {
    var layoutDirection: LayoutDirection? {
        switch self {
        case .system: nil
        case .english: .leftToRight
        case .arabic: .rightToLeft
        }
    }

    /// The direction the device itself reads in. Shared, because anything rendered outside the
    /// view hierarchy — the exported text card — has to reach the same answer the root does, and
    /// a hardcoded left-to-right fallback there produced a preview and an export that disagreed.
    static var systemLayoutDirection: LayoutDirection {
        let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
        return Locale.Language(identifier: code).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

private extension UserSettings.Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
