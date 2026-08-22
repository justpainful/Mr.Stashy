import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab(L10n.value("tab.catch"), systemImage: "link.badge.plus", value: AppModel.Tab.catchTab) {
                CatchView()
            }
            Tab(L10n.value("tab.library"), systemImage: "archivebox", value: AppModel.Tab.library) {
                LibraryView()
            }
            Tab(L10n.value("tab.queue"), systemImage: "arrow.down.circle", value: AppModel.Tab.queue) {
                QueueView()
            }
            .badge(model.activeJobCount)
            Tab(L10n.value("tab.settings"), systemImage: "slider.horizontal.3", value: AppModel.Tab.settings) {
                SettingsView()
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(4))
                        if model.banner?.id == banner.id { model.banner = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.banner)
        .sheet(isPresented: Binding(get: { !model.settings.onboardingDone }, set: { if !$0 { model.settings.onboardingDone = true } })) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
    }
}

struct BannerView: View {
    var banner: AppModel.Banner
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Theme.warn : Theme.verified)
            Text(banner.text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
            }
            .accessibilityLabel(L10n.value("common.dismiss"))
        }
        .padding(12)
        .card()
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Stashy")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(L10n.value("onboarding.tagline"))
                .font(.title3)
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 18) {
                OnboardingRow(symbol: "link", text: L10n.value("onboarding.point1"))
                OnboardingRow(symbol: "4k.tv", text: L10n.value("onboarding.point2"))
                OnboardingRow(symbol: "iphone.and.arrow.forward", text: L10n.value("onboarding.point3"))
            }
            .padding(.top, 36)
            Spacer()
            Button(L10n.value("onboarding.start")) {
                model.settings.onboardingDone = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.start")
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.paper)
    }
}

private struct OnboardingRow: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.amber)
                .frame(width: 28)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.ink)
        }
    }
}
