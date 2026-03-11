import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechRecognizerService: TranscriptionEngine {
    let engineName = "Apple Speech"
    private let stopFinalizeHardTimeoutMs = 10_000
    private let stopFinalizeInactivityDelayMs = 900
    private let stopFinalizeCheckIntervalMs = 160
    private static let fallbackRecognitionLocaleIdentifier = "en-US"
    private static let englishRegionLocaleMap = [
        "US": "en-US",
        "IN": "en-IN",
        "GB": "en-GB"
    ]
    private static let contextualVocabulary = [
        "Voice",
        "Voice app",
        "dictation",
        "transcription",
        "speech recognizer",
        "speech recognition",
        "Git",
        "GitHub",
        "git commit",
        "git checkout",
        "git pull",
        "git push",
        "pull request",
        "merge conflict",
        "cherry-pick",
        "rebase",
        "squash merge",
        "code review",
        "Xcode",
        "Swift",
        "SwiftUI",
        "macOS",
        "AVAudioEngine",
        "SFSpeechRecognizer",
        "SpeechRecognizerService",
        "TranscriptionEngine",
        "VoiceRuntimeError",
        "API",
        "REST API",
        "GraphQL",
        "endpoint",
        "JSON",
        "YAML",
        "OpenAPI",
        "backend",
        "frontend",
        "full stack",
        "database",
        "PostgreSQL",
        "MySQL",
        "SQLite",
        "Redis",
        "migration",
        "transaction",
        "TypeScript",
        "JavaScript",
        "Node.js",
        "React",
        "Next.js",
        "Python",
        "Go",
        "Rust",
        "Java",
        "Kotlin",
        "C plus plus",
        "Docker",
        "Kubernetes",
        "CI CD",
        "GitHub Actions",
        "build pipeline",
        "unit test",
        "integration test",
        "regression test",
        "test coverage",
        "lint",
        "formatter",
        "refactor",
        "debug",
        "stack trace",
        "exception",
        "memory leak",
        "race condition",
        "deadlock",
        "thread safe",
        "concurrency",
        "async await",
        "command line",
        "terminal",
        "shell script",
        "Bash",
        "Zsh",
        "Makefile",
        "dependency injection",
        "microservice",
        "monorepo"
    ]

    private enum EngineState {
        case idle
        case starting
        case running
        case stopping
    }

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engineState: EngineState = .idle

    private var transcriptHandler: TranscriptHandler?
    private var completionHandler: CompletionHandler?
    private var currentTranscript = ""
    private var completionDelivered = false
    private var isTapInstalled = false
    private var audioTapAppender: AudioTapAppender?
    private var stopFinalizeTask: Task<Void, Never>?
    private var stopFinalizeDeadline: Date?
    private var stopLastTranscriptUpdateAt: Date?
    private var hasReceivedPostStopTranscript = false

    func start(
        options: TranscriptionStartOptions,
        transcriptHandler: @escaping TranscriptionEngine.TranscriptHandler,
        completionHandler: @escaping TranscriptionEngine.CompletionHandler
    ) throws {
        AppLogger.shared.log("Speech start requested with profile: \(options.profile.rawValue)", level: .info)

        guard engineState == .idle else {
            AppLogger.shared.log("Speech start ignored — engine is currently \(engineState)", level: .warning)
            return
        }

        cancelRunningTask()
        engineState = .starting

        let recognitionLocale = resolveRecognitionLocale()
        AppLogger.shared.log("Using explicit speech locale: \(recognitionLocale.identifier)", level: .info)
        let speechRecognizer = SFSpeechRecognizer(locale: recognitionLocale)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            engineState = .idle
            AppLogger.shared.log("Speech recognizer unavailable", level: .error)
            throw VoiceRuntimeError.recognizerUnavailable
        }

        self.transcriptHandler = transcriptHandler
        self.completionHandler = completionHandler
        currentTranscript = ""
        completionDelivered = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Self.contextualVocabulary
        switch options.profile {
        case .appleAutomatic:
            request.requiresOnDeviceRecognition = false
        case .appleOnDevicePreferred:
            if speechRecognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            } else {
                request.requiresOnDeviceRecognition = false
                AppLogger.shared.log(
                    "On-device recognition not supported for locale \(recognitionLocale.identifier) or current device; falling back to automatic mode.",
                    level: .warning
                )
            }
        }
        recognitionRequest = request
        let tapAppender = AudioTapAppender(request: request)
        audioTapAppender = tapAppender

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        removeAudioTapIfNeeded()
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: makeAudioTapBlock(appender: tapAppender)
        )
        isTapInstalled = true
        engineState = .running

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            AppLogger.shared.log("Failed to start AVAudioEngine: \(error.localizedDescription)", level: .error)
            removeAudioTapIfNeeded()
            engineState = .idle
            throw error
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            Task { @MainActor [weak self] in
                self?.handleRecognitionEvent(
                    transcript: transcript,
                    isFinal: isFinal,
                    errorDescription: errorDescription
                )
            }
        }
    }

    func stop() {
        guard engineState == .running else {
            AppLogger.shared.log("Speech stop ignored — engine is \(engineState)", level: .warning)
            return
        }

        AppLogger.shared.log("Speech stop requested", level: .info)
        engineState = .stopping
        audioEngine.stop()
        removeAudioTapIfNeeded()
        recognitionRequest?.endAudio()
        stopLastTranscriptUpdateAt = nil
        hasReceivedPostStopTranscript = false
        stopFinalizeDeadline = Date().addingTimeInterval(TimeInterval(stopFinalizeHardTimeoutMs) / 1_000)
        scheduleStopFinalizeCheck()
    }

    func cancel() {
        AppLogger.shared.log("Speech cancel requested", level: .debug)
        audioEngine.stop()
        removeAudioTapIfNeeded()
        cancelRunningTask()
    }

    private func handleRecognitionEvent(transcript: String?, isFinal: Bool, errorDescription: String?) {
        if let transcript {
            updateCurrentTranscriptKeepingLongest(transcript)
            transcriptHandler?(currentTranscript)
            if isFinal {
                finish(with: .success(currentTranscript))
                return
            }
            if engineState == .stopping {
                hasReceivedPostStopTranscript = true
                stopLastTranscriptUpdateAt = Date()
            }
        }

        if let errorDescription {
            AppLogger.shared.log("Speech recognition error: \(errorDescription)", level: .error)
            finish(with: .failure(mapSpeechError(errorDescription)))
        }
    }

    private func mapSpeechError(_ errorDescription: String) -> Error {
        if errorDescription.localizedCaseInsensitiveContains("siri and dictation are disabled") {
            return VoiceRuntimeError.siriAndDictationDisabled
        }

        return VoiceMessageError(message: errorDescription)
    }

    private func finish(with result: Result<String, Error>) {
        guard !completionDelivered else {
            return
        }

        stopFinalizeTask?.cancel()
        stopFinalizeTask = nil
        stopFinalizeDeadline = nil
        stopLastTranscriptUpdateAt = nil
        hasReceivedPostStopTranscript = false
        completionDelivered = true
        switch result {
        case .success(let text):
            AppLogger.shared.log("Speech completed with transcript length \(text.count)", level: .info)
        case .failure(let error):
            AppLogger.shared.log("Speech finished with error: \(error.localizedDescription)", level: .error)
        }
        completionHandler?(result)
        cancelRunningTask()
    }

    private func cancelRunningTask() {
        stopFinalizeTask?.cancel()
        stopFinalizeTask = nil
        stopFinalizeDeadline = nil
        stopLastTranscriptUpdateAt = nil
        hasReceivedPostStopTranscript = false
        audioEngine.stop()
        removeAudioTapIfNeeded()
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest = nil
        audioTapAppender = nil
        transcriptHandler = nil
        completionHandler = nil
        engineState = .idle
    }

    private func removeAudioTapIfNeeded() {
        guard isTapInstalled else {
            return
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func finishIfNeededFromCurrentTranscript() {
        guard !completionDelivered else {
            return
        }

        let finalText = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalText.isEmpty {
            finish(with: .failure(VoiceRuntimeError.emptyTranscript))
        } else {
            finish(with: .success(finalText))
        }
    }

    private func scheduleStopFinalizeCheck() {
        stopFinalizeTask?.cancel()
        stopFinalizeTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: .milliseconds(self.stopFinalizeCheckIntervalMs))
            self.evaluateStopFinalize()
        }
    }

    private func evaluateStopFinalize() {
        guard engineState == .stopping, !completionDelivered else {
            return
        }

        let now = Date()
        if let deadline = stopFinalizeDeadline, now >= deadline {
            AppLogger.shared.log("Speech finalize hard timeout reached; finishing with best available transcript.", level: .warning)
            finishIfNeededFromCurrentTranscript()
            return
        }

        if hasReceivedPostStopTranscript,
           let lastUpdate = stopLastTranscriptUpdateAt {
            let inactiveMs = Int(now.timeIntervalSince(lastUpdate) * 1_000)
            if inactiveMs >= stopFinalizeInactivityDelayMs {
                finishIfNeededFromCurrentTranscript()
                return
            }
        }

        scheduleStopFinalizeCheck()
    }

    private func updateCurrentTranscriptKeepingLongest(_ candidate: String) {
        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTrimmed = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidateTrimmed.count >= currentTrimmed.count {
            currentTranscript = candidate
        }
    }

    private func resolveRecognitionLocale() -> Locale {
        for preferredLanguage in Locale.preferredLanguages {
            let normalizedIdentifier = Self.normalizedLocaleIdentifier(preferredLanguage)
            if normalizedIdentifier == "en-US" || normalizedIdentifier == "en-IN" || normalizedIdentifier == "en-GB" {
                return Locale(identifier: normalizedIdentifier)
            }

            let subtags = normalizedIdentifier.split(separator: "-")
            let languageCode = subtags.first?.lowercased()
            guard languageCode == "en" else {
                continue
            }

            let regionCode = subtags.dropFirst().first(where: { $0.count == 2 || $0.count == 3 })?.uppercased()
            if let regionCode,
               let mappedIdentifier = Self.englishRegionLocaleMap[regionCode] {
                return Locale(identifier: mappedIdentifier)
            }

            return Locale(identifier: Self.fallbackRecognitionLocaleIdentifier)
        }

        return Locale(identifier: Self.fallbackRecognitionLocaleIdentifier)
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }
}

private struct VoiceMessageError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class AudioTapAppender: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let levelReporter = AudioLevelReporter()

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
        levelReporter.report(level: normalizedAudioLevel(from: buffer))
    }
}

private func makeAudioTapBlock(appender: AudioTapAppender) -> AVAudioNodeTapBlock {
    { buffer, _ in
        appender.append(buffer)
    }
}

private func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channels = buffer.floatChannelData else {
        return 0
    }

    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else {
        return 0
    }

    let channel = channels[0]
    var squaredSum: Float = 0
    for index in 0..<frameCount {
        let sample = channel[index]
        squaredSum += sample * sample
    }

    let rms = sqrtf(squaredSum / Float(frameCount))
    let clampedRms = max(rms, 0.000_001)
    let db = 20 * log10f(clampedRms)
    let normalized = (db + 55) / 55
    return max(0, min(1, CGFloat(normalized)))
}

private final class AudioLevelReporter: @unchecked Sendable {
    private var lastPostedAt: Double = 0

    func report(level: CGFloat) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPostedAt >= 0.03 else {
            return
        }
        lastPostedAt = now

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .voiceAudioLevelDidUpdate,
                object: nil,
                userInfo: [VoiceAudioLevelUserInfoKey.level: level]
            )
        }
    }
}
