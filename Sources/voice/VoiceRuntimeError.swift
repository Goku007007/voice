import Foundation

enum VoiceRuntimeError: LocalizedError {
    case recognizerUnavailable
    case emptyTranscript
    case speechPermissionMissing
    case microphonePermissionMissing
    case siriAndDictationDisabled
    case accessibilityPermissionMissing
    case keyboardEventCreationFailed
    case hotkeyRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable for the current locale."
        case .emptyTranscript:
            return "No speech was detected."
        case .speechPermissionMissing:
            return "Speech Recognition permission is not granted. Enable it in System Settings > Privacy & Security > Speech Recognition."
        case .microphonePermissionMissing:
            return "Microphone permission is not granted. Enable it in System Settings > Privacy & Security > Microphone."
        case .siriAndDictationDisabled:
            return "Siri and Dictation are disabled. Enable Dictation in System Settings > Keyboard > Dictation, then try again."
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required to insert dictated text."
        case .keyboardEventCreationFailed:
            return "Unable to synthesize keyboard events."
        case .hotkeyRegistrationFailed(let status):
            return "Unable to register global hotkey (OSStatus \(status))."
        }
    }
}
