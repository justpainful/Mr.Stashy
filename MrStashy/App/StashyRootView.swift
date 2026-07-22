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
        .tint(StashyTheme.green)
        .preferredColorScheme(appState.settings.appearance.colorScheme)
        .environment(\.locale, appState.settings.language.locale)
        .environment(\.accessibilityReduceMotion, systemReduceMotion || appState.settings.reduceMotion)
        .onOpenURL(perform: appState.handleOpenURL)
        .alert(String(localized: "error.title"), isPresented: Binding(get: { appState.lastError != nil }, set: { if !$0 { appState.lastError = nil } })) {
            Button(String(localized: "action.done")) { appState.lastError = nil }
        } message: {
            Text(appState.lastError?.message ?? "")
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
            NavigationStack { SettingsView() }
                .tabItem { Label(L10n.value(AppTab.settings.titleKey), systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
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
