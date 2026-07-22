import SwiftUI

struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onComplete: () -> Void
    @State private var step = 0

    private let pages: [(String, String, String)] = [
        ("onboarding.paste.title", "onboarding.paste.body", "link.badge.plus"),
        ("onboarding.find.title", "onboarding.find.body", "sparkle.magnifyingglass"),
        ("onboarding.choose.title", "onboarding.choose.body", "checklist"),
        ("onboarding.local.title", "onboarding.local.body", "externaldrive.fill.badge.checkmark")
    ]

    var body: some View {
        ZStack {
            StashyBackground()
            VStack(spacing: 24) {
                HStack {
                    Text(String(localized: "app.name"))
                        .font(.system(.largeTitle, design: .rounded, weight: .black))
                    Spacer()
                    Button(String(localized: "onboarding.skip"), action: onComplete)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("onboarding.skip")
                }
                .padding(.horizontal, 24)

                TabView(selection: $step) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        VStack(spacing: 24) {
                            Image(systemName: page.2)
                                .font(.system(size: 82, weight: .medium))
                                .foregroundStyle(StashyTheme.lavender)
                                .frame(height: 180)
                                .accessibilityHidden(true)
                            Text(L10n.value(page.0))
                                .font(.system(.title, design: .rounded, weight: .bold))
                                .multilineTextAlignment(.center)
                            Text(L10n.value(page.1))
                                .font(.body)
                                .foregroundStyle(colorScheme == .dark ? StashyTheme.cream.opacity(0.76) : StashyTheme.charcoal.opacity(0.76))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 36)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button(step == pages.count - 1 ? String(localized: "onboarding.finish") : String(localized: "onboarding.next")) {
                    if step == pages.count - 1 { onComplete() } else { withAnimation { step += 1 } }
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("onboarding.continue")
            }
            .padding(.vertical, 16)
        }
    }
}
