import Foundation

enum InsertionMode: String, CaseIterable {
    case directPaste
    case clipboardOnly

    var title: String {
        switch self {
        case .directPaste:
            return "Direct Paste"
        case .clipboardOnly:
            return "Clipboard Only"
        }
    }
}

enum RecordingMode: String, CaseIterable {
    case toggle
    case pushToTalk

    var title: String {
        switch self {
        case .toggle:
            return "Toggle (Press Once)"
        case .pushToTalk:
            return "Push-to-Talk (Hold)"
        }
    }
}

enum TranscriptionProfile: String, CaseIterable {
    case appleAutomatic
    case appleOnDevicePreferred

    var title: String {
        switch self {
        case .appleAutomatic:
            return "Apple Speech (Automatic)"
        case .appleOnDevicePreferred:
            return "Apple Speech (On-Device Preferred)"
        }
    }

    var description: String {
        switch self {
        case .appleAutomatic:
            return "Best compatibility. May use Apple's network services."
        case .appleOnDevicePreferred:
            return "Local-first when available for your language and device."
        }
    }
}

struct AppSettings {
    var removeFillerWords: Bool
    var autoPunctuation: Bool
    var capitalizeFirstLetter: Bool
    var insertionMode: InsertionMode
    var recordingMode: RecordingMode
    var transcriptionProfile: TranscriptionProfile
    var cleanupMode: CleanupMode
    var soundFeedback: Bool

    static let `default` = AppSettings(
        removeFillerWords: true,
        autoPunctuation: true,
        capitalizeFirstLetter: true,
        insertionMode: .directPaste,
        recordingMode: .toggle,
        transcriptionProfile: .appleOnDevicePreferred,
        cleanupMode: .basic,
        soundFeedback: true
    )
}
