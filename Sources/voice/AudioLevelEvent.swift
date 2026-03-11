import Foundation

extension Notification.Name {
    static let voiceAudioLevelDidUpdate = Notification.Name("com.voice.app.audioLevelDidUpdate")
}

enum VoiceAudioLevelUserInfoKey {
    static let level = "level"
}
