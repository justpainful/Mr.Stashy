import SwiftUI

struct TextCardComposer: View {
    let post: ResolvedPost
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var style: TextCardStyle = .editorial
    @State private var appearance: TextCardAppearance = .light
    @State private var includeAuthor = true
    @State private var includeTimestamp = true
    @State private var saveToPhotos = false
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TextCardCanvas(
                        post: post,
                        style: style,
                        appearance: appearance,
                        includeAuthor: includeAuthor,
                        includeTimestamp: includeTimestamp
                    )
                    .frame(height: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 28))

                    Picker(L10n.value("textCard.template"), selection: $style) {
                        ForEach(TextCardStyle.allCases) { style in Text(L10n.value(style.titleKey)).tag(style) }
                    }
                    .pickerStyle(.segmented)

                    Picker(L10n.value("textCard.appearance"), selection: $appearance) {
                        ForEach(TextCardAppearance.allCases) { appearance in Text(L10n.value(appearance.titleKey)).tag(appearance) }
                    }
                    .pickerStyle(.segmented)

                    Toggle(L10n.value("textCard.includeAuthor"), isOn: $includeAuthor)
                    Toggle(L10n.value("textCard.includeTimestamp"), isOn: $includeTimestamp)
                    Toggle(L10n.value("textCard.saveToPhotos"), isOn: $saveToPhotos)

                    Button { Task { await save() } } label: {
                        Label(L10n.value(didSave ? "textCard.saved" : "textCard.save"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("textCard.save")
                }
                .padding(20)
            }
            .navigationTitle(L10n.value("textCard.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text(L10n.value("action.done")))
                }
            }
        }
        .task { saveToPhotos = appState.settings.saveToPhotos }
    }

    @MainActor
    private func save() async {
        let canvas = TextCardCanvas(
            post: post,
            style: style,
            appearance: appearance,
            includeAuthor: includeAuthor,
            includeTimestamp: includeTimestamp
        )
        let renderer = ImageRenderer(content: canvas.frame(width: 1080, height: 1350))
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else {
            appState.lastError = UserVisibleError(message: L10n.value("textCard.error.render"))
            return
        }

        do {
            let summary = try await appState.archiveStore.saveTextCard(pngData: data, sourcePost: post)
            appState.libraryPosts = await appState.archiveStore.loadSummaries()
            didSave = true
            if saveToPhotos,
               let url = await appState.archiveStore.localMediaURL(archiveID: summary.id, filename: "0-text-card.png") {
                do {
                    try await PhotoLibrarySaver.save(url: url, type: .photo)
                } catch {
                    appState.lastError = UserVisibleError(message: error.localizedDescription)
                }
            }
        } catch {
            appState.lastError = UserVisibleError(message: error.localizedDescription)
        }
    }
}

enum TextCardStyle: String, CaseIterable, Identifiable {
    case neutral, compact, editorial
    var id: String { rawValue }
    var titleKey: String { "textCard.style.\(rawValue)" }
}

enum TextCardAppearance: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var titleKey: String { "textCard.appearance.\(rawValue)" }
}

struct TextCardCanvas: View {
    let post: ResolvedPost
    let style: TextCardStyle
    let appearance: TextCardAppearance
    let includeAuthor: Bool
    let includeTimestamp: Bool

    private var isRTL: Bool { post.text.isLikelyArabic }
    private var alignment: Alignment { isRTL ? .topTrailing : .topLeading }
    private var textAlignment: TextAlignment { isRTL ? .trailing : .leading }

    var body: some View {
        let colors = palette
        ZStack(alignment: .bottomTrailing) {
            colors.background
            VStack(alignment: isRTL ? .trailing : .leading, spacing: 18) {
                if includeAuthor {
                    HStack(spacing: 9) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                        VStack(alignment: isRTL ? .trailing : .leading, spacing: 2) {
                            Text(post.author.displayName).font(.system(.headline, design: .rounded, weight: .bold))
                            if let username = post.author.username {
                                Text("@\(username)").font(.caption).opacity(0.75)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                ViewThatFits(in: .vertical) {
                    cardText(size: fontSizes[0])
                    cardText(size: fontSizes[1])
                    cardText(size: fontSizes[2])
                    cardText(size: fontSizes[3])
                }

                HStack {
                    Text(L10n.value(post.platform.titleKey))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(Capsule().stroke(colors.foreground.opacity(0.35), lineWidth: 1))
                    Spacer()
                    if includeTimestamp, let createdAt = post.createdAt {
                        Text(createdAt, style: .date).font(.caption).opacity(0.75)
                    }
                }
            }
            .foregroundStyle(colors.foreground)
            .padding(34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .accessibilityHidden(true)
        }
        .accessibilityLabel(Text(L10n.value("textCard.preview")))
    }

    private func cardText(size: CGFloat) -> some View {
        Text(post.text.isEmpty ? L10n.value("textCard.empty") : post.text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var fontSizes: [CGFloat] {
        switch style {
        case .compact: [32, 29, 26, 23]
        case .neutral: [40, 35, 30, 26]
        case .editorial: [44, 38, 32, 27]
        }
    }

    private var palette: (background: Color, foreground: Color) {
        switch (style, appearance) {
        case (_, .dark): (StashyTheme.darkSurface, StashyTheme.cream)
        case (.editorial, .light): (StashyTheme.lavender, StashyTheme.charcoal)
        case (.compact, .light): (StashyTheme.butter, StashyTheme.charcoal)
        case (.neutral, .light): (StashyTheme.cream, StashyTheme.charcoal)
        }
    }
}

private extension String {
    var isLikelyArabic: Bool { unicodeScalars.contains { (0x0600 ... 0x06FF).contains($0.value) } }
}
