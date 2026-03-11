import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechRecognizerService: TranscriptionEngine {
    let engineName = "Apple Speech"
    private let stopFinalizeHardTimeoutMs = 10_000
    private let stopFinalizeInactivityDelayMs = 900

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

        let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
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
        switch options.profile {
        case .appleAutomatic:
            request.requiresOnDeviceRecognition = false
        case .appleOnDevicePreferred:
            if speechRecognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            } else {
                request.requiresOnDeviceRecognition = false
                AppLogger.shared.log(
                    "On-device recognition not supported for current locale/device; falling back to automatic mode.",
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
        stopFinalizeDeadline = Date().addingTimeInterval(TimeInterval(stopFinalizeHardTimeoutMs) / 1_000)
        scheduleStopFinalize(usingInactivityDelay: stopFinalizeInactivityDelayMs)
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
                scheduleStopFinalize(usingInactivityDelay: stopFinalizeInactivityDelayMs)
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

    private func scheduleStopFinalize(usingInactivityDelay delayMs: Int) {
        let remainingMs: Int
        if let deadline = stopFinalizeDeadline {
            remainingMs = max(0, Int(deadline.timeIntervalSinceNow * 1_000))
        } else {
            remainingMs = delayMs
        }
        let waitMs = min(delayMs, remainingMs)

        stopFinalizeTask?.cancel()
        stopFinalizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(waitMs))
            self?.finishIfNeededFromCurrentTranscript()
        }
    }

    private func updateCurrentTranscriptKeepingLongest(_ candidate: String) {
        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTrimmed = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidateTrimmed.count >= currentTrimmed.count {
            currentTranscript = candidate
        }
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
