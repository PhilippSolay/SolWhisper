import AVFoundation
import Combine
import Foundation

/// Thin wrapper around `AVAudioPlayer` that publishes play state + position
/// for SwiftUI bindings. One controller per meeting detail view.
///
/// The store owns the audio file; this controller just plays it. Created
/// lazily when the user opens a meeting and discarded when they switch away.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    let url: URL
    private var player: AVAudioPlayer?
    private var tickTimer: Timer?

    init(url: URL) {
        self.url = url
        super.init()
        prepare()
    }

    deinit {
        tickTimer?.invalidate()
        player?.stop()
    }

    // MARK: - Playback

    func play() {
        guard let player else { return }
        if !player.isPlaying {
            player.play()
            isPlaying = true
            startTicks()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        tickTimer?.invalidate()
        tickTimer = nil
        // Latch the final position so the seek bar doesn't snap.
        if let player { currentTime = player.currentTime }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    /// Seeks to `seconds` from the start of the audio. Clamped to [0, duration].
    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(seconds, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    // MARK: - Private

    private func prepare() {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
            currentTime = 0
        } catch {
            DebugLog.shared.log(icon: "🔊", label: "Audio prepare failed",
                                value: "\(url.lastPathComponent): \(error)", ok: false)
        }
    }

    private func startTicks() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.tickTimer?.invalidate()
            self.tickTimer = nil
            self.currentTime = self.duration
        }
    }
}
