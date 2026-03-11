import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechRecognizerService: TranscriptionEngine {
    let engineName = "Apple Speech"
    private let stopFinalizeHardTimeoutMs = 10_000
    private let stopFinalizeInactivityDelayMs = 900
    private let stopFinalizeCheckIntervalMs = 160
    private let rollingRestartDelayMs = 220
    nonisolated private static let customLanguageModelIdentifier = "com.voice.app.technical"
    nonisolated private static let customLanguageModelVersion = "2026.03.11.02"
    nonisolated private static let fallbackRecognitionLocaleIdentifier = "en-US"
    nonisolated private static let englishRegionLocaleMap = [
        "US": "en-US",
        "IN": "en-IN",
        "GB": "en-GB"
    ]
    nonisolated private static let contextualVocabulary = [
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
    nonisolated private static let customLanguageModelPriorityPhrases: [(phrase: String, count: Int)] = [
        ("git", 80),
        ("GitHub", 240),
        ("GitHub repo", 200),
        ("GitHub repository", 200),
        ("open GitHub", 190),
        ("on GitHub", 190),
        ("from GitHub", 180),
        ("to GitHub", 160),
        ("GitHub issue", 180),
        ("GitHub branch", 170),
        ("GitHub pull request", 190),
        ("GitHub Actions", 170),
        ("git commit", 120),
        ("git checkout", 120),
        ("git pull", 120),
        ("git push", 120),
        ("pull request", 100),
        ("merge conflict", 80),
        ("cherry-pick", 75),
        ("rebase", 75),
        ("code review", 75),
        ("Xcode", 85),
        ("VS Code", 85),
        ("Swift", 90),
        ("SwiftUI", 70),
        ("Node.js", 80),
        ("TypeScript", 80),
        ("JavaScript", 80),
        ("PostgreSQL", 80),
        ("MySQL", 65),
        ("SQLite", 65),
        ("Redis", 65),
        ("Docker", 75),
        ("Kubernetes", 75),
        ("OpenAI", 75),
        ("REST API", 95),
        ("GraphQL", 75),
        ("endpoint", 70),
        ("JSON", 95),
        ("YAML", 95),
        ("CI/CD", 85),
        ("build pipeline", 75),
        ("integration test", 70),
        ("unit test", 70),
        ("regression test", 70),
        ("command line", 70),
        ("terminal", 70),
        ("async await", 65)
    ]
    nonisolated private static let customLanguageModelCommandPhrases: [String] = [
        "git add",
        "git status",
        "git log",
        "git fetch",
        "git merge",
        "git stash",
        "git branch",
        "git revert",
        "git reset",
        "git diff",
        "create pull request",
        "open pull request",
        "merge pull request",
        "resolve merge conflict",
        "run unit tests",
        "run integration tests",
        "run regression tests",
        "build and deploy",
        "debug stack trace",
        "REST API endpoint",
        "GraphQL endpoint",
        "JSON payload",
        "YAML file",
        "GitHub repo",
        "GitHub repository",
        "GitHub issue",
        "GitHub pull request",
        "GitHub branch",
        "on GitHub",
        "open GitHub",
        "open VS Code",
        "open Xcode",
        "in Visual Studio Code",
        "in Xcode",
        "in terminal"
    ]

    private enum EngineState {
        case idle
        case starting
        case running
        case stopping
    }

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engineState: EngineState = .idle

    private var activeStartOptions: TranscriptionStartOptions?
    private var activeRecognitionLocale: Locale?
    private var transcriptHandler: TranscriptHandler?
    private var completionHandler: CompletionHandler?
    private var finalizedTranscript = ""
    private var activeTaskTranscript = ""
    private var currentTranscript = ""
    private var completionDelivered = false
    private var activeRecognitionTaskID = 0
    private var isTapInstalled = false
    private var audioTapAppender: AudioTapAppender?
    private var pendingRecognitionRestartTask: Task<Void, Never>?
    private var stopFinalizeTask: Task<Void, Never>?
    private var stopFinalizeDeadline: Date?
    private var stopLastTranscriptUpdateAt: Date?
    private var hasReceivedPostStopTranscript = false
    private var customLanguageModelPreparationTask: Task<Void, Never>?
    private var customLanguageModelPreparedLocaleIdentifier: String?
    private var customLanguageModelPreparingLocaleIdentifier: String?
    private var customLanguageModelConfiguration: Any?

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
        beginCustomLanguageModelPreparationIfNeeded(for: recognitionLocale)
        AppLogger.shared.log("Using explicit speech locale: \(recognitionLocale.identifier)", level: .info)
        let recognizer = SFSpeechRecognizer(locale: recognitionLocale)
        guard let recognizer, recognizer.isAvailable else {
            engineState = .idle
            AppLogger.shared.log("Speech recognizer unavailable", level: .error)
            throw VoiceRuntimeError.recognizerUnavailable
        }

        self.speechRecognizer = recognizer
        activeStartOptions = options
        activeRecognitionLocale = recognitionLocale
        self.transcriptHandler = transcriptHandler
        self.completionHandler = completionHandler
        finalizedTranscript = ""
        activeTaskTranscript = ""
        currentTranscript = ""
        completionDelivered = false
        activeRecognitionTaskID = 0

        let request = makeRecognitionRequest(
            speechRecognizer: recognizer,
            options: options,
            recognitionLocale: recognitionLocale
        )
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

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            AppLogger.shared.log("Failed to start AVAudioEngine: \(error.localizedDescription)", level: .error)
            removeAudioTapIfNeeded()
            engineState = .idle
            throw error
        }

        engineState = .running
        startRecognitionTask(with: request)
    }

    func warmUpLanguageAssets() {
        beginCustomLanguageModelPreparationIfNeeded(for: resolveRecognitionLocale())
    }

    private func makeRecognitionRequest(
        speechRecognizer: SFSpeechRecognizer,
        options: TranscriptionStartOptions,
        recognitionLocale: Locale
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Self.contextualVocabulary
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        AppLogger.shared.log(
            "Loaded \(Self.contextualVocabulary.count) contextual terms for locale \(recognitionLocale.identifier)",
            level: .debug
        )

        let normalizedLocaleIdentifier = Self.normalizedLocaleIdentifier(recognitionLocale.identifier)
        var appliedCustomLanguageModel = false
        if #available(macOS 14.0, *),
           speechRecognizer.supportsOnDeviceRecognition,
           let customLanguageModel = customLanguageModelConfigurationIfReady(for: normalizedLocaleIdentifier) {
            request.customizedLanguageModel = customLanguageModel
            request.requiresOnDeviceRecognition = true
            appliedCustomLanguageModel = true
            AppLogger.shared.log(
                "Using prepared custom language model for locale \(normalizedLocaleIdentifier).",
                level: .info
            )
        }

        if !appliedCustomLanguageModel {
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

            if #available(macOS 14.0, *) {
                AppLogger.shared.log(
                    "Custom language model not ready for locale \(normalizedLocaleIdentifier); using standard recognizer path.",
                    level: .debug
                )
            }
        }

        return request
    }

    private func startRecognitionTask(with request: SFSpeechAudioBufferRecognitionRequest) {
        guard let speechRecognizer else {
            finish(with: .failure(VoiceRuntimeError.recognizerUnavailable))
            return
        }

        activeRecognitionTaskID += 1
        let taskID = activeRecognitionTaskID
        recognitionTask?.cancel()
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            Task { @MainActor [weak self] in
                self?.handleRecognitionEvent(
                    transcript: transcript,
                    isFinal: isFinal,
                    errorDescription: errorDescription,
                    taskID: taskID
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
        pendingRecognitionRestartTask?.cancel()
        pendingRecognitionRestartTask = nil
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
        pendingRecognitionRestartTask?.cancel()
        pendingRecognitionRestartTask = nil
        audioEngine.stop()
        removeAudioTapIfNeeded()
        cancelRunningTask()
    }

    private func handleRecognitionEvent(transcript: String?, isFinal: Bool, errorDescription: String?, taskID: Int) {
        guard taskID == activeRecognitionTaskID else {
            return
        }

        if let transcript {
            updateActiveTaskTranscriptKeepingLongest(transcript)
            publishCombinedTranscript()
            if engineState == .stopping {
                hasReceivedPostStopTranscript = true
                stopLastTranscriptUpdateAt = Date()
            }
        }

        if isFinal {
            commitActiveTaskTranscriptIfNeeded()
            if engineState == .stopping {
                finishIfNeededFromCurrentTranscript()
            } else if engineState == .running {
                scheduleRollingRecognitionRestart(reason: "final-result", delayMs: 40)
            }
            return
        }

        if let errorDescription {
            handleRecognitionError(errorDescription)
        }
    }

    private func handleRecognitionError(_ errorDescription: String) {
        if engineState == .running, isCancellationLikeError(errorDescription) {
            AppLogger.shared.log(
                "Speech chunk ended with cancellation; starting next chunk.",
                level: .debug
            )
            commitActiveTaskTranscriptIfNeeded()
            scheduleRollingRecognitionRestart(reason: "cancellation", delayMs: 80)
            return
        }

        if engineState == .running, isRecoverableRecognitionError(errorDescription) {
            AppLogger.shared.log(
                "Speech recognition recoverable error: \(errorDescription). Restarting chunk.",
                level: .warning
            )
            commitActiveTaskTranscriptIfNeeded()
            scheduleRollingRecognitionRestart(reason: "recoverable-error", delayMs: rollingRestartDelayMs)
            return
        }

        if engineState == .stopping, isBenignErrorWhileStopping(errorDescription) {
            finishIfNeededFromCurrentTranscript()
            return
        }

        AppLogger.shared.log("Speech recognition error: \(errorDescription)", level: .error)
        finish(with: .failure(mapSpeechError(errorDescription)))
    }

    private func scheduleRollingRecognitionRestart(reason: String, delayMs: Int) {
        guard engineState == .running, !completionDelivered else {
            return
        }

        pendingRecognitionRestartTask?.cancel()
        pendingRecognitionRestartTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }

            self.restartRecognitionTask(reason: reason)
        }
    }

    private func restartRecognitionTask(reason: String) {
        guard engineState == .running, !completionDelivered else {
            return
        }

        guard let speechRecognizer,
              let activeStartOptions,
              let activeRecognitionLocale else {
            finish(with: .failure(VoiceRuntimeError.recognizerUnavailable))
            return
        }

        let request = makeRecognitionRequest(
            speechRecognizer: speechRecognizer,
            options: activeStartOptions,
            recognitionLocale: activeRecognitionLocale
        )
        recognitionRequest = request
        audioTapAppender?.updateRequest(request)
        activeTaskTranscript = ""
        startRecognitionTask(with: request)

        AppLogger.shared.log(
            "Speech chunk restarted (\(reason)). Current transcript length \(combinedTranscriptSnapshot().count).",
            level: .debug
        )
    }

    private func publishCombinedTranscript() {
        currentTranscript = combinedTranscriptSnapshot()
        transcriptHandler?(currentTranscript)
    }

    private func commitActiveTaskTranscriptIfNeeded() {
        let chunk = activeTaskTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else {
            return
        }

        finalizedTranscript = mergedTranscript(base: finalizedTranscript, chunk: chunk)
        activeTaskTranscript = ""
        publishCombinedTranscript()
    }

    private func combinedTranscriptSnapshot() -> String {
        let partial = activeTaskTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else {
            return finalizedTranscript
        }
        return mergedTranscript(base: finalizedTranscript, chunk: partial)
    }

    private func mergedTranscript(base: String, chunk: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else {
            return trimmedBase
        }
        guard !trimmedBase.isEmpty else {
            return trimmedChunk
        }

        if trimmedBase.localizedCaseInsensitiveCompare(trimmedChunk) == .orderedSame {
            return trimmedBase
        }

        if trimmedBase.lowercased().hasSuffix(trimmedChunk.lowercased()) {
            return trimmedBase
        }

        if trimmedChunk.lowercased().hasPrefix(trimmedBase.lowercased()) {
            return trimmedChunk
        }

        return "\(trimmedBase) \(trimmedChunk)"
    }

    private func updateActiveTaskTranscriptKeepingLongest(_ candidate: String) {
        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTrimmed = activeTaskTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidateTrimmed.count >= currentTrimmed.count {
            activeTaskTranscript = candidate
        }
    }

    private func isRecoverableRecognitionError(_ errorDescription: String) -> Bool {
        let lowered = errorDescription.lowercased()
        if lowered.contains("siri and dictation are disabled") {
            return false
        }

        return lowered.contains("no speech detected")
            || lowered.contains("timed out")
            || lowered.contains("timeout")
            || lowered.contains("temporarily unavailable")
            || lowered.contains("interrupted")
            || lowered.contains("kafassistanterrordomain")
    }

    private func isCancellationLikeError(_ errorDescription: String) -> Bool {
        let lowered = errorDescription.lowercased()
        return lowered.contains("recognition request was canceled")
            || lowered.contains("recognition request was cancelled")
            || lowered.contains("request was canceled")
            || lowered.contains("request was cancelled")
    }

    private func isBenignErrorWhileStopping(_ errorDescription: String) -> Bool {
        let lowered = errorDescription.lowercased()
        return lowered.contains("no speech detected") || isCancellationLikeError(errorDescription)
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
        pendingRecognitionRestartTask?.cancel()
        pendingRecognitionRestartTask = nil
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
        pendingRecognitionRestartTask?.cancel()
        pendingRecognitionRestartTask = nil
        audioEngine.stop()
        removeAudioTapIfNeeded()
        activeRecognitionTaskID += 1
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest = nil
        speechRecognizer = nil
        audioTapAppender?.updateRequest(nil)
        audioTapAppender = nil
        activeStartOptions = nil
        activeRecognitionLocale = nil
        finalizedTranscript = ""
        activeTaskTranscript = ""
        currentTranscript = ""
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

        commitActiveTaskTranscriptIfNeeded()
        let finalText = combinedTranscriptSnapshot().trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func beginCustomLanguageModelPreparationIfNeeded(for locale: Locale) {
        guard #available(macOS 14.0, *) else {
            return
        }

        let normalizedLocaleIdentifier = Self.normalizedLocaleIdentifier(locale.identifier)
        guard normalizedLocaleIdentifier.lowercased().hasPrefix("en") else {
            return
        }

        if customLanguageModelPreparedLocaleIdentifier == normalizedLocaleIdentifier {
            return
        }

        if customLanguageModelPreparingLocaleIdentifier == normalizedLocaleIdentifier {
            return
        }

        customLanguageModelPreparingLocaleIdentifier = normalizedLocaleIdentifier
        customLanguageModelPreparationTask?.cancel()
        customLanguageModelPreparationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let configuration = try await Self.prepareCustomLanguageModelConfiguration(for: locale)
                guard !Task.isCancelled else {
                    return
                }
                self.customLanguageModelConfiguration = configuration
                self.customLanguageModelPreparedLocaleIdentifier = normalizedLocaleIdentifier
                AppLogger.shared.log(
                    "Custom language model prepared for locale \(normalizedLocaleIdentifier).",
                    level: .info
                )
            } catch {
                AppLogger.shared.log(
                    "Custom language model preparation failed for locale \(normalizedLocaleIdentifier): \(error.localizedDescription)",
                    level: .warning
                )
            }

            self.customLanguageModelPreparingLocaleIdentifier = nil
        }
    }

    @available(macOS 14.0, *)
    private func customLanguageModelConfigurationIfReady(for localeIdentifier: String) -> SFSpeechLanguageModel.Configuration? {
        guard customLanguageModelPreparedLocaleIdentifier == localeIdentifier else {
            return nil
        }
        return customLanguageModelConfiguration as? SFSpeechLanguageModel.Configuration
    }

    @available(macOS 14.0, *)
    nonisolated private static func prepareCustomLanguageModelConfiguration(for locale: Locale) async throws -> SFSpeechLanguageModel.Configuration {
        let localeIdentifier = normalizedLocaleIdentifier(locale.identifier)
        let urls = try customLanguageModelURLs(for: localeIdentifier)
        let customModelData = buildCustomLanguageModelData(for: locale)

        try await customModelData.export(to: urls.assetURL)

        let configuration = SFSpeechLanguageModel.Configuration(languageModel: urls.languageModelURL)
        let clientIdentifier = Bundle.main.bundleIdentifier ?? "com.voice.app"
        try await prepareCustomLanguageModel(
            assetURL: urls.assetURL,
            configuration: configuration,
            clientIdentifier: clientIdentifier
        )

        return configuration
    }

    @available(macOS 14.0, *)
    nonisolated private static func customLanguageModelURLs(for localeIdentifier: String) throws -> (assetURL: URL, languageModelURL: URL) {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let modelDirectory = baseDirectory
            .appendingPathComponent("voice/CustomLanguageModels", isDirectory: true)
            .appendingPathComponent(localeIdentifier, isDirectory: true)

        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let assetURL = modelDirectory.appendingPathComponent("lm-data-\(customLanguageModelVersion).bin", isDirectory: false)
        let languageModelURL = modelDirectory.appendingPathComponent("prepared-lm-\(customLanguageModelVersion).bin", isDirectory: false)
        return (assetURL, languageModelURL)
    }

    @available(macOS 14.0, *)
    nonisolated private static func buildCustomLanguageModelData(for locale: Locale) -> SFCustomLanguageModelData {
        let customModelData = SFCustomLanguageModelData(
            locale: locale,
            identifier: customLanguageModelIdentifier,
            version: customLanguageModelVersion
        )

        for phrase in contextualVocabulary {
            customModelData.insert(
                phraseCount: SFCustomLanguageModelData.PhraseCount(
                    phrase: phrase,
                    count: 14
                )
            )
        }

        for phrase in customLanguageModelCommandPhrases {
            customModelData.insert(
                phraseCount: SFCustomLanguageModelData.PhraseCount(
                    phrase: phrase,
                    count: 26
                )
            )
        }

        for weightedPhrase in customLanguageModelPriorityPhrases {
            customModelData.insert(
                phraseCount: SFCustomLanguageModelData.PhraseCount(
                    phrase: weightedPhrase.phrase,
                    count: weightedPhrase.count
                )
            )
        }

        return customModelData
    }

    @available(macOS 14.0, *)
    nonisolated private static func prepareCustomLanguageModel(
        assetURL: URL,
        configuration: SFSpeechLanguageModel.Configuration,
        clientIdentifier: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: assetURL,
                clientIdentifier: clientIdentifier,
                configuration: configuration,
                ignoresCache: false
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
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

    nonisolated private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
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
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let levelReporter = AudioLevelReporter()

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func updateRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let activeRequest = request
        lock.unlock()
        activeRequest?.append(buffer)
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
