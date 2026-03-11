import Foundation

extension Notification.Name {
    static let voiceAudioLevelDidUpdate = Notification.Name("ai.gokul.voice.audioLevelDidUpdate")
}

enum VoiceAudioLevelUserInfoKey {
    static let level = "level"
}
