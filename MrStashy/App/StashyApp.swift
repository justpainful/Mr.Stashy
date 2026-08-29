import SwiftUI

@main
struct StashyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(scheme)
                .environment(\.layoutDirection, L10n.isRightToLeft ? .rightToLeft : .leftToRight)
                .environment(\.locale, Locale(identifier: model.settings.language.localeIdentifier ?? Locale.current.identifier))
                .tint(Theme.amber)
                .task { await model.bootstrap() }
                .onOpenURL { model.handle(openURL: $0) }
        }
    }

    private var scheme: ColorScheme? {
        switch model.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
