import Foundation

struct TranscriptionStartOptions {
    let profile: TranscriptionProfile
}

@MainActor
protocol TranscriptionEngine: AnyObject {
    typealias TranscriptHandler = (String) -> Void
    typealias CompletionHandler = (Result<String, Error>) -> Void

    var engineName: String { get }
    func start(
        options: TranscriptionStartOptions,
        transcriptHandler: @escaping TranscriptHandler,
        completionHandler: @escaping CompletionHandler
    ) throws
    func stop()
    func cancel()
}
