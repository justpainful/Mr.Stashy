import SwiftUI

@main
struct MrStashyApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StashyRootView()
                .environment(appState)
                .task { await appState.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    appState.consumePendingShares()
                }
        }
    }
}
