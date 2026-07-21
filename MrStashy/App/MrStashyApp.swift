import SwiftUI

@main
struct MrStashyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            StashyRootView()
                .environment(appState)
                .task { await appState.bootstrap() }
        }
    }
}
