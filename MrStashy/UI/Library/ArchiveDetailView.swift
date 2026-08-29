import AVKit
import SwiftUI

struct ArchiveDetailView: View {
    var archiveID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: ArchiveManifest?
    @State private var page = 0
    @State private var fullscreen: ArchivedFile?

    private var summary: ArchiveSummary? { model.library.first { $0.id == archiveID } }

    var body: some View {
        ScrollView {
            if let manifest {
                VStack(alignment: .leading, spacing: 16) {
                    pager(manifest)
                    header(manifest)
                    if !manifest.text.isEmpty {
                        Text(manifest.text)
                            .font(.body)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                    }
                    files(manifest)
                    if !manifest.missing.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L10n.value("detail.missing"), systemImage: "exclamationmark.triangle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.warn)
                            ForEach(manifest.missing, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.muted) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                    ForEach(manifest.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Link(destination: manifest.canonicalURL) {
                        Label(L10n.value("detail.openSource"), systemImage: "safari")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(16)
            } else {
                ProgressView().padding(40)
            }
        }
        .background(Theme.paper)
        .navigationTitle(summary?.authorName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let summary {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ArchiveActions(summary: summary) { dismiss() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("detail.menu")
                }
            }
        }
        .task(id: archiveID) { manifest = try? await model.store.manifest(for: archiveID) }
        .fullScreenCover(item: $fullscreen) { file in
            MediaViewer(file: file, folder: model.store.archivesDirectoryURL(folder: archiveID.uuidString))
        }
    }

    private func pager(_ manifest: ArchiveManifest) -> some View {
        let folder = model.store.archivesDirectoryURL(folder: archiveID.uuidString)
        return VStack(spacing: 8) {
            TabView(selection: $page) {
                ForEach(Array(manifest.files.enumerated()), id: \.offset) { index, file in
                    MediaPage(file: file, folder: folder)
                        .tag(index)
                        .onTapGesture { fullscreen = file }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            if manifest.files.count > 1 {
                HStack(spacing: 6) {
                    ForEach(manifest.files.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Theme.amber : Theme.rule)
                            .frame(width: index == page ? 18 : 6, height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: page)
            }
        }
    }

    private func header(_ manifest: ArchiveManifest) -> some View {
        HStack(spacing: 12) {
            PlatformGlyph(platform: manifest.platform, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.title.flatMap { $0.isEmpty ? nil : $0 } ?? manifest.author.display)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if manifest.title?.isEmpty == false { Text(manifest.author.display).lineLimit(1) }
                    Text(L10n.date(manifest.createdAt ?? manifest.savedAt, time: .omitted))
                }
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(14)
        .card()
    }

    private func files(_ manifest: ArchiveManifest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.plural("detail.files", manifest.files.count))
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .padding(14)
            Divider().overlay(Theme.rule)
            ForEach(manifest.files) { file in
                HStack(spacing: 10) {
                    Image(systemName: file.kind.systemImage)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.value(file.kind.titleKey))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        SpecLine([resolution(file), file.codec, Format.bytes(file.sizeBytes), Format.duration(file.duration)], verified: true)
                    }
                    Spacer()
                    Button {
                        ShareSheet.present(model.store.archivesDirectoryURL(folder: archiveID.uuidString).appendingPathComponent(file.filename))
                    } label: {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.amber)
                    }
                    .accessibilityLabel(L10n.value("common.share"))
                }
                .padding(12)
                if file.id != manifest.files.last?.id { Divider().overlay(Theme.rule).padding(.leading, 44) }
            }
        }
        .card()
    }

    private func resolution(_ file: ArchivedFile) -> String? {
        guard let width = file.width, let height = file.height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }
}

/// One page of the media pager: a still for pictures and videos, with a play mark for videos.
struct MediaPage: View {
    var file: ArchivedFile
    var folder: URL

    var body: some View {
        ZStack {
            Theme.cardRaised
            switch file.kind {
            case .photo, .gif:
                LocalImage(url: folder.appendingPathComponent(file.filename), maxPixels: 1200, contentMode: .fit)
            case .video:
                LocalImage(url: folder.appendingPathComponent("cover-\(file.index).jpg"), maxPixels: 1200, contentMode: .fit)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
            case .audio:
                Image(systemName: "waveform")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.muted)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Full-screen playback and zoomable pictures.
struct MediaViewer: View {
    var file: ArchivedFile
    var folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            switch file.kind {
            case .video, .audio:
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        let player = AVPlayer(url: folder.appendingPathComponent(file.filename))
                        self.player = player
                        player.play()
                    }
                    .onDisappear { player?.pause() }
            case .photo, .gif:
                ZoomableImage(url: folder.appendingPathComponent(file.filename))
                    .ignoresSafeArea()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(16)
            .accessibilityLabel(L10n.value("common.close"))
            .accessibilityIdentifier("viewer.close")
        }
    }
}

struct ZoomableImage: UIViewRepresentable {
    var url: URL

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        tap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(tap)
        Task {
            let image = await ImageCache.shared.image(for: url, maxPixels: 3000)
            imageView.image = image
        }
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(width: scrollView.bounds.width / 3, height: scrollView.bounds.height / 3)
                scrollView.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
            }
        }
    }
}
