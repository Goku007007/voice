import AppKit
import Foundation

@MainActor
final class AudioFeedbackPlayer {
    static let shared = AudioFeedbackPlayer()

    private var soundsEnabled = true

    func setEnabled(_ enabled: Bool) {
        soundsEnabled = enabled
    }

    func playStart() {
        guard soundsEnabled else { return }
        NSSound(named: "Morse")?.play()
    }

    func playStop() {
        guard soundsEnabled else { return }
        NSSound(named: "Purr")?.play()
    }
}

