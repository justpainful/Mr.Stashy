import AVFoundation
import Foundation

/// The app's audio route.
///
/// Without this, every video Stashy plays is silent whenever the ring/silent switch is on: the
/// default `AVAudioSession` category for an app that never configures one is `.soloAmbient`,
/// which obeys the mute switch. A person watching a saved video expects to hear it, exactly as
/// they would in the app the post came from.
///
/// The session is reference counted. It is activated when the first player starts and released
/// when the last one stops, so Stashy does not sit on the audio route — and does not keep music
/// from another app interrupted — once nothing is playing.
enum MediaPlaybackSession {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeCount = 0

    /// Claims the playback route. Balance every call with `release()`.
    static func acquire() {
        lock.lock()
        let wasIdle = activeCount == 0
        activeCount += 1
        lock.unlock()
        guard wasIdle else { return }
        let session = AVAudioSession.sharedInstance()
        // `.playback` is the category for media the person deliberately chose to watch, and it
        // is what makes sound work with the ring switch silenced.
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true, options: [])
    }

    static func release() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        let isIdle = activeCount == 0
        lock.unlock()
        guard isIdle else { return }
        // Telling the system the session is finished lets whatever was playing before Stashy
        // resume, instead of leaving it ducked or stopped.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
