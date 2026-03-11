import Foundation

@MainActor
final class SettingsStore {
    var onChange: ((AppSettings) -> Void)?

    private enum Key {
        static let removeFillerWords = "voice.settings.removeFillerWords"
        static let autoPunctuation = "voice.settings.autoPunctuation"
        static let capitalizeFirstLetter = "voice.settings.capitalizeFirstLetter"
        static let insertionMode = "voice.settings.insertionMode"
        static let recordingMode = "voice.settings.recordingMode"
        static let transcriptionProfile = "voice.settings.transcriptionProfile"
        static let cleanupMode = "voice.settings.cleanupMode"
        static let soundFeedback = "voice.settings.soundFeedback"
    }

    private let defaults: UserDefaults

    private(set) var current: AppSettings {
        didSet {
            persist(current)
            onChange?(current)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.current = AppSettings(
            removeFillerWords: defaults.object(forKey: Key.removeFillerWords) as? Bool ?? AppSettings.default.removeFillerWords,
            autoPunctuation: defaults.object(forKey: Key.autoPunctuation) as? Bool ?? AppSettings.default.autoPunctuation,
            capitalizeFirstLetter: defaults.object(forKey: Key.capitalizeFirstLetter) as? Bool ?? AppSettings.default.capitalizeFirstLetter,
            insertionMode: InsertionMode(rawValue: defaults.string(forKey: Key.insertionMode) ?? "") ?? AppSettings.default.insertionMode,
            recordingMode: RecordingMode(rawValue: defaults.string(forKey: Key.recordingMode) ?? "") ?? AppSettings.default.recordingMode,
            transcriptionProfile: TranscriptionProfile(rawValue: defaults.string(forKey: Key.transcriptionProfile) ?? "") ?? AppSettings.default.transcriptionProfile,
            cleanupMode: CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? AppSettings.default.cleanupMode,
            soundFeedback: defaults.object(forKey: Key.soundFeedback) as? Bool ?? AppSettings.default.soundFeedback
        )
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var updated = current
        mutate(&updated)
        current = updated
    }

    private func persist(_ settings: AppSettings) {
        defaults.set(settings.removeFillerWords, forKey: Key.removeFillerWords)
        defaults.set(settings.autoPunctuation, forKey: Key.autoPunctuation)
        defaults.set(settings.capitalizeFirstLetter, forKey: Key.capitalizeFirstLetter)
        defaults.set(settings.insertionMode.rawValue, forKey: Key.insertionMode)
        defaults.set(settings.recordingMode.rawValue, forKey: Key.recordingMode)
        defaults.set(settings.transcriptionProfile.rawValue, forKey: Key.transcriptionProfile)
        defaults.set(settings.cleanupMode.rawValue, forKey: Key.cleanupMode)
        defaults.set(settings.soundFeedback, forKey: Key.soundFeedback)
    }
}
