import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

// Video playback, rebuilt.
//
// The previous player put every saved video inside a fixed 220–420pt box with no regard for the
// video's own shape, created an `AVPlayer` for each one the moment the row existed, and showed a
// spinner forever when a file would not play. This file replaces all three behaviours: a video is
// shown at its real aspect ratio, a player exists only while it is on screen, and a file that
// cannot be decoded says so.

/// What an inline player is currently doing, so the view can show the right thing instead of a
/// spinner that never resolves.
enum VideoPlaybackPhase: Equatable {
    case loading
    case ready
    case failed(String)
}

/// Owns one `AVPlayer` and everything the view needs to know about it.
///
/// Deliberately a class the view creates and tears down with `onAppear`/`onDisappear`: a grid of
/// saved posts must not hold a decoder open for every video it has ever scrolled past.
@MainActor
@Observable
final class VideoPlaybackModel {
    private(set) var phase: VideoPlaybackPhase = .loading
    /// The video's own width ÷ height, read from its track. `nil` until the asset loads.
    private(set) var naturalAspect: CGFloat?
    private(set) var isPlaying = false
    var isMuted = false {
        didSet { player?.isMuted = isMuted }
    }

    private(set) var player: AVPlayer?
    private var url: URL?
    private var loopsAtEnd = false
    private var cancellables: Set<AnyCancellable> = []
    private var holdsAudioSession = false
    private var loadTask: Task<Void, Never>?

    /// Creates the player for `url`. Calling it again with the same address is a no-op, so a
    /// SwiftUI update does not restart playback from the beginning.
    func start(url: URL, autoplay: Bool, loops: Bool, muted: Bool) {
        guard self.url != url else { return }
        stop()
        self.url = url
        loopsAtEnd = loops
        isMuted = muted
        phase = .loading

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let created = AVPlayer(playerItem: item)
        created.isMuted = muted
        // Nothing here is a live stream, so let the system show the route picker and mirror.
        created.allowsExternalPlayback = true
        player = created

        // A file that fails to open used to leave a spinner on screen with no explanation. The
        // item's own status is the only reliable signal for that, so the view listens to it.
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.phase = .ready
                case .failed:
                    let reason = item.error?.localizedDescription ?? L10n.value("media.playback.failed")
                    self.phase = .failed(reason)
                    self.releaseAudioSession()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        created.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = status == .playing }
            .store(in: &cancellables)

        if loops {
            NotificationCenter.default
                .publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.player?.seek(to: .zero)
                    self?.player?.play()
                }
                .store(in: &cancellables)
        }

        loadTask = Task { [weak self] in
            let aspect = await VideoGeometry.aspectRatio(of: asset)
            guard !Task.isCancelled else { return }
            self?.naturalAspect = aspect
        }

        if autoplay { play() }
    }

    func play() {
        guard let player else { return }
        acquireAudioSession()
        player.play()
    }

    func pause() {
        player?.pause()
        releaseAudioSession()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Releases the decoder and the audio route. Called when the view leaves the screen.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        player?.pause()
        // Pausing alone leaves the item — and its decoder — attached. Detaching it is what
        // actually frees the memory when a list of saved videos is scrolled.
        player?.replaceCurrentItem(with: nil)
        player = nil
        url = nil
        isPlaying = false
        naturalAspect = nil
        phase = .loading
        releaseAudioSession()
    }

    private func acquireAudioSession() {
        guard !holdsAudioSession else { return }
        holdsAudioSession = true
        MediaPlaybackSession.acquire()
    }

    private func releaseAudioSession() {
        guard holdsAudioSession else { return }
        holdsAudioSession = false
        MediaPlaybackSession.release()
    }
}

enum VideoGeometry {
    /// The displayed width ÷ height of a video, honouring the rotation its container records.
    /// A portrait clip recorded on a phone reports a landscape natural size plus a transform, and
    /// ignoring that transform is what made portrait videos letterbox into a landscape box.
    static func aspectRatio(of asset: AVAsset) async -> CGFloat? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let displayed = size.applying(transform)
        let width = abs(displayed.width)
        let height = abs(displayed.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }

    /// Keeps an extreme ratio from turning a card into a sliver or a full page.
    static func clamped(_ ratio: CGFloat?, fallback: CGFloat = 16.0 / 9.0) -> CGFloat {
        guard let ratio, ratio.isFinite, ratio > 0 else { return fallback }
        return min(max(ratio, 0.4), 2.4)
    }
}

// MARK: - Inline player

/// A saved video shown in place, at its own aspect ratio, with the controls a person expects.
///
/// It starts paused with a poster frame and a play button. That is deliberate: a library screen
/// where every video starts talking at once is unusable, and it is also why the audio route is
/// only claimed once someone actually presses play.
struct InlineVideoPlayer: View {
    let url: URL
    /// A ratio already known from the archive manifest, used until the asset reports its own.
    var declaredAspect: CGFloat?
    var cornerRadius: CGFloat = 16
    var loops: Bool = false
    /// Opens the dedicated full-screen player. When `nil`, the expand control is not offered.
    var onExpand: ((URL) -> Void)?

    @State private var model = VideoPlaybackModel()
    @State private var hasStarted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var aspect: CGFloat {
        VideoGeometry.clamped(model.naturalAspect ?? declaredAspect)
    }

    var body: some View {
        ZStack {
            switch model.phase {
            case .failed(let reason):
                VideoUnavailable(reason: reason)
            case .loading, .ready:
                if let player = model.player {
                    VideoPlayer(player: player)
                } else {
                    Color.black
                }
            }
            if !hasStarted, case .ready = model.phase {
                posterOverlay
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) { expandButton }
        .onAppear {
            model.start(url: url, autoplay: false, loops: loops && !reduceMotion, muted: false)
        }
        .onDisappear { model.stop() }
        .onChange(of: url) { _, newValue in
            hasStarted = false
            model.stop()
            model.start(url: newValue, autoplay: false, loops: loops && !reduceMotion, muted: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.value("media.video")))
        .accessibilityHint(Text(L10n.value("media.playback.hint")))
    }

    private var posterOverlay: some View {
        Button {
            hasStarted = true
            model.play()
        } label: {
            ZStack {
                Color.black.opacity(0.28)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(color: .black.opacity(0.35), radius: 6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.value("media.playback.play")))
    }

    @ViewBuilder private var expandButton: some View {
        if let onExpand {
            Button { onExpand(url) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(Text(L10n.value("media.playback.fullScreen")))
        }
    }
}

/// Shown when a saved file genuinely will not play, instead of a spinner that never ends.
struct VideoUnavailable: View {
    let reason: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(StashyTheme.butter)
            Text(L10n.value("media.playback.failed"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Full screen

/// The dedicated player a video opens into: system controls, Picture in Picture, AirPlay, and
/// the scrubber people already know, because it is `AVPlayerViewController` rather than a
/// hand-built approximation of it.
struct FullScreenVideoPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var model = VideoPlaybackModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .failed(let reason):
                VideoUnavailable(reason: reason).ignoresSafeArea()
            case .loading, .ready:
                if let player = model.player {
                    SystemVideoPlayer(player: player).ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            }
            closeButton
        }
        .onAppear { model.start(url: url, autoplay: true, loops: false, muted: false) }
        .onDisappear { model.stop() }
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                // A 44pt target, which the old 12pt-padded glyph was not.
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
        }
        .padding(16)
        .accessibilityLabel(Text(L10n.value("media.playback.close")))
    }
}

/// `AVPlayerViewController`, which is what actually provides Picture in Picture, the AirPlay
/// route button, and the standard transport controls. SwiftUI's `VideoPlayer` exposes none of
/// them, which is why the full-screen player uses this directly.
private struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}
