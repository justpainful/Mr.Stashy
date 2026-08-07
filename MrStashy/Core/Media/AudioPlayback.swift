import AVFoundation
import Combine
import SwiftUI

// Saved audio used to be a link that handed the file to another app. Nothing about an archive
// justifies leaving Stashy to hear what Stashy saved, so audio now plays in place, with the
// transport controls a person expects: play/pause, a scrubber, elapsed and total time, and a
// 15-second skip in each direction.

@MainActor
@Observable
final class AudioPlaybackModel {
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var failure: String?
    /// The scrubber's position. Set by the view while dragging, otherwise driven by the player.
    var currentTime: TimeInterval = 0
    var isScrubbing = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var holdsAudioSession = false
    private var url: URL?

    func start(url: URL) {
        guard self.url != url else { return }
        stop()
        self.url = url
        let item = AVPlayerItem(url: url)
        let created = AVPlayer(playerItem: item)
        player = created

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .failed {
                    self.failure = item.error?.localizedDescription ?? L10n.value("media.playback.failed")
                } else if status == .readyToPlay {
                    let seconds = item.duration.seconds
                    self.duration = seconds.isFinite && seconds > 0 ? seconds : 0
                }
            }
            .store(in: &cancellables)

        created.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = status == .playing }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.player?.seek(to: .zero)
                self?.currentTime = 0
                self?.pause()
            }
            .store(in: &cancellables)

        // Four updates a second keeps the scrubber honest without waking the main thread more
        // than a progress indicator needs.
        timeObserver = created.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player, failure == nil else { return }
        if !holdsAudioSession {
            holdsAudioSession = true
            MediaPlaybackSession.acquire()
        }
        player.play()
    }

    func pause() {
        player?.pause()
        releaseAudioSession()
    }

    func seek(to seconds: TimeInterval) {
        let clamped = min(max(seconds, 0), duration > 0 ? duration : seconds)
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func stop() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        cancellables.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        url = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        failure = nil
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        guard holdsAudioSession else { return }
        holdsAudioSession = false
        MediaPlaybackSession.release()
    }
}

/// An in-app audio player for a saved audio file.
struct AudioPlaybackView: View {
    let url: URL
    var title: String?

    @State private var model = AudioPlaybackModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(StashyTheme.inkSecondary)
            } else {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                Slider(
                    value: Binding(
                        get: { model.currentTime },
                        set: { model.currentTime = $0 }
                    ),
                    in: 0 ... max(model.duration, 0.01),
                    onEditingChanged: { editing in
                        model.isScrubbing = editing
                        if !editing { model.seek(to: model.currentTime) }
                    }
                )
                .disabled(model.duration <= 0)
                .accessibilityLabel(Text(L10n.value("media.playback.position")))
                .accessibilityValue(Text(ThumbnailBadge.durationText(model.currentTime)))

                HStack {
                    Text(ThumbnailBadge.durationText(model.currentTime))
                    Spacer()
                    Text(ThumbnailBadge.durationText(model.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(StashyTheme.inkSecondary)
                .accessibilityHidden(true)

                HStack(spacing: 24) {
                    Spacer(minLength: 0)
                    transportButton("gobackward.15", label: "media.playback.back15") { model.skip(by: -15) }
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.value(model.isPlaying ? "media.playback.pause" : "media.playback.play")))
                    transportButton("goforward.15", label: "media.playback.forward15") { model.skip(by: 15) }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(StashyTheme.hairline, lineWidth: 1))
        .onAppear { model.start(url: url) }
        .onDisappear { model.stop() }
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(model.duration <= 0)
        .accessibilityLabel(Text(L10n.value(label)))
    }
}
