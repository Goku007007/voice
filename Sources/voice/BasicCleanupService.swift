import Foundation

@MainActor
final class BasicCleanupService: TranscriptCleanupService {
    func clean(_ text: String, settings: AppSettings, appContext: AppContext?) async -> String {
        TextPostProcessor.clean(text, settings: settings)
    }
}
