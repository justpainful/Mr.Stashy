import SwiftUI

/// Everything about the card that changes what a save would produce. Comparing the whole
/// configuration is what keeps the button honest: a Bool stayed on "Saved" after the template
/// changed, so the second card was written with no feedback that anything had happened.
struct TextCardConfiguration: Equatable {
    var style: TextCardStyle = .editorial
    var appearance: TextCardAppearance = .light
    var includeAuthor = true
    var includeTimestamp = true
}

struct TextCardComposer: View {
    let post: ResolvedPost
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var config = TextCardConfiguration()
    @State private var saveToPhotos = false
    @State private var savedConfiguration: TextCardConfiguration?
    @State private var isSaving = false

    private var isAlreadySaved: Bool { savedConfiguration == config }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // The preview lays out at the exact geometry the export uses and is scaled
                    // down to fit. Previewing at a different shape made `ViewThatFits` choose a
                    // different font size than the render did, so the card someone approved was
                    // not the card that was written.
                    GeometryReader { proxy in
                        canvas
                            .frame(width: 1_080, height: 1_350)
                            .scaleEffect(proxy.size.width / 1_080, anchor: .topLeading)
                    }
                    .aspectRatio(1_080.0 / 1_350.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 28))

                    Picker(L10n.value("textCard.template"), selection: $config.style) {
                        ForEach(TextCardStyle.allCases) { style in Text(L10n.value(style.titleKey)).tag(style) }
                    }
                    .pickerStyle(.segmented)

                    Picker(L10n.value("textCard.appearance"), selection: $config.appearance) {
                        ForEach(TextCardAppearance.allCases) { appearance in Text(L10n.value(appearance.titleKey)).tag(appearance) }
                    }
                    .pickerStyle(.segmented)

                    Toggle(L10n.value("textCard.includeAuthor"), isOn: $config.includeAuthor)
                    Toggle(L10n.value("textCard.includeTimestamp"), isOn: $config.includeTimestamp)
                    Toggle(L10n.value("textCard.saveToPhotos"), isOn: $saveToPhotos)

                    Button { Task { await save() } } label: {
                        Label(L10n.value(isAlreadySaved ? "textCard.saved" : "textCard.save"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.glassProminent)
                    // Two quick taps used to mint two archives, because the flag was only set
                    // after the write finished.
                    .disabled(isSaving || isAlreadySaved)
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

    private var canvas: TextCardCanvas {
        TextCardCanvas(post: post, configuration: config)
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // An `ImageRenderer` tree stands outside the app's hierarchy, so it never receives the
        // locale and layout direction the root installs. Without them the exported PNG carried
        // an English date and a left-to-right layout while the preview showed neither.
        let rendered = canvas
            .frame(width: 1_080, height: 1_350)
            .environment(\.locale, appState.settings.language.locale)
            .environment(\.layoutDirection, appState.settings.language.layoutDirection ?? UserSettings.AppLanguage.systemLayoutDirection)
        let renderer = ImageRenderer(content: rendered)
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else {
            appState.lastError = UserVisibleError(message: L10n.value("textCard.error.render"))
            return
        }

        do {
            let summary = try await appState.archiveStore.saveTextCard(pngData: data, sourcePost: post)
            appState.libraryPosts = await appState.archiveStore.loadSummaries()
            savedConfiguration = config
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
    let configuration: TextCardConfiguration

    private var style: TextCardStyle { configuration.style }
    private var appearance: TextCardAppearance { configuration.appearance }

    var body: some View {
        let colors = palette
        ZStack(alignment: .bottomTrailing) {
            colors.background
            // The card overrides its own layout direction from the post's text and then uses
            // plain `.leading` throughout. Hand-substituting `.trailing` for right-to-left, as
            // this did, mirrors an already direction-relative constant back the wrong way.
            VStack(alignment: .leading, spacing: 18) {
                if configuration.includeAuthor {
                    HStack(spacing: 9) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.author.displayName).font(.system(.headline, design: .rounded, weight: .bold))
                            if let handle = post.author.displayHandle {
                                Text(handle).font(.caption).opacity(0.75)
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
                    if configuration.includeTimestamp, let createdAt = post.createdAt {
                        Text(createdAt, style: .date).font(.caption).opacity(0.75)
                    }
                }
            }
            .foregroundStyle(colors.foreground)
            .padding(34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.layoutDirection, post.text.isRightToLeftText ? .rightToLeft : .leftToRight)
        // Hiding the children and labelling the container made the whole preview vanish from the
        // accessibility tree: without `children: .ignore` the container is not an element, so the
        // label had nothing to attach to and the four controls above changed nothing perceivable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.value("textCard.preview")))
        .accessibilityValue(Text(post.text.isEmpty ? L10n.value("textCard.empty") : post.text))
    }

    private func cardText(size: CGFloat) -> some View {
        Text(post.text.isEmpty ? L10n.value("textCard.empty") : post.text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fontSizes: [CGFloat] {
        switch style {
        case .compact: [32, 29, 26, 23]
        case .neutral: [40, 35, 30, 26]
        case .editorial: [44, 38, 32, 27]
        }
    }

    /// Every pairing carries its text at or above the 4.5:1 contrast ratio. The editorial card
    /// used to put near-black charcoal on a saturated indigo, which is 1.5:1 — a card nobody
    /// could read, exported at full resolution and saved to Photos.
    private var palette: (background: Color, foreground: Color) {
        switch (style, appearance) {
        case (_, .dark): (StashyTheme.darkSurface, StashyTheme.cream)
        case (.editorial, .light): (StashyTheme.lavender, StashyTheme.cream)
        case (.compact, .light): (StashyTheme.butter, StashyTheme.charcoal)
        case (.neutral, .light): (StashyTheme.cream, StashyTheme.charcoal)
        }
    }
}

extension String {
    /// The first strong-directional character decides a paragraph's direction (UAX #9). Asking
    /// whether the text *contains* an Arabic letter flipped a mostly-English post on one word,
    /// and missed Hebrew, Thaana, and the Arabic presentation forms entirely.
    var isRightToLeftText: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0590 ... 0x08FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF:
                return true
            case 0x0041 ... 0x005A, 0x0061 ... 0x007A, 0x00C0 ... 0x024F, 0x0370 ... 0x058F:
                return false
            default:
                continue
            }
        }
        return false
    }
}
