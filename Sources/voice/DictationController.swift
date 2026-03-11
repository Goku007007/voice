import AppKit
import Foundation

@MainActor
final class DictationController {
    var onStatusChanged: ((VoiceStatus) -> Void)?
    var onInsertionStatusChanged: ((String) -> Void)?

    private let settingsStore: SettingsStore
    private let permissionsCoordinator: PermissionsCoordinator
    private let transcriptionEngine: TranscriptionEngine
    private let textInsertionService: TextInsertionService
    private let panelController: FloatingStatusPanelController
    private let cleanupService: TranscriptCleanupService

    private(set) var status: VoiceStatus = .idle {
        didSet {
            onStatusChanged?(status)
        }
    }

    private var liveTranscript = ""
    private var insertionAppContext: AppContext?

    init(
        settingsStore: SettingsStore,
        permissionsCoordinator: PermissionsCoordinator,
        transcriptionEngine: TranscriptionEngine,
        textInsertionService: TextInsertionService,
        panelController: FloatingStatusPanelController,
        cleanupService: TranscriptCleanupService
    ) {
        self.settingsStore = settingsStore
        self.permissionsCoordinator = permissionsCoordinator
        self.transcriptionEngine = transcriptionEngine
        self.textInsertionService = textInsertionService
        self.panelController = panelController
        self.cleanupService = cleanupService
    }

    func handleHotkeyPressed() {
        toggleDictation()
    }

    func toggleDictation() {
        switch status {
        case .idle, .error:
            startDictation()
        case .listening:
            stopDictation()
        case .processing:
            break
        }
    }

    func stopIfNeeded() {
        if case .listening = status {
            transcriptionEngine.cancel()
            status = .idle
        }
    }

    private func startDictation() {
        AppLogger.shared.log("Dictation toggle: start requested")
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let frontApp = NSWorkspace.shared.frontmostApplication
            self.insertionAppContext = AppContext(
                bundleIdentifier: frontApp?.bundleIdentifier,
                appName: frontApp?.localizedName
            )
            do {
                try await self.ensureSpeechAndMicrophonePermissions()
                self.beginDictationSession()
            } catch {
                self.fail(with: error)
            }
        }
    }

    private func beginDictationSession() {
        AppLogger.shared.log("Dictation session started")
        liveTranscript = ""
        status = .listening
        panelController.show(status: "Listening", transcript: nil)

        if settingsStore.current.soundFeedback {
            AudioFeedbackPlayer.shared.playStart()
        }

        do {
            try transcriptionEngine.start(
                options: TranscriptionStartOptions(profile: settingsStore.current.transcriptionProfile),
                transcriptHandler: { [weak self] transcript in
                    Task { @MainActor in
                        self?.handlePartialTranscript(transcript)
                    }
                },
                completionHandler: { [weak self] result in
                    Task { @MainActor in
                        self?.handleFinalResult(result)
                    }
                }
            )
        } catch {
            fail(with: error)
        }
    }

    private func stopDictation() {
        guard case .listening = status else {
            return
        }

        AppLogger.shared.log("Dictation session stopping")
        status = .processing
        panelController.show(status: "Processing", transcript: nil)

        if settingsStore.current.soundFeedback {
            AudioFeedbackPlayer.shared.playStop()
        }

        transcriptionEngine.stop()
    }

    private func handlePartialTranscript(_ transcript: String) {
        liveTranscript = transcript

        if case .listening = status {
            panelController.show(status: "Listening", transcript: transcript)
        }
    }

    private func handleFinalResult(_ result: Result<String, Error>) {
        switch result {
        case .success(let text):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.processAndInsert(rawText: text)
            }
        case .failure(let error):
            fail(with: error)
        }
    }

    private func processAndInsert(rawText: String) async {
        let settings = settingsStore.current
        let isLLMMode = settings.cleanupMode != .basic

        if isLLMMode {
            panelController.show(status: "Processing", transcript: nil)
        } else {
            panelController.show(status: "Processing", transcript: nil)
        }

        let processedText = await cleanupService.clean(rawText, settings: settings, appContext: insertionAppContext)
        AppLogger.shared.log(
            "Transcript raw (\(rawText.count) chars): \(transcriptPreview(rawText))",
            level: .debug
        )
        AppLogger.shared.log(
            "Transcript cleaned (\(processedText.count) chars): \(transcriptPreview(processedText))",
            level: .debug
        )

        guard !processedText.isEmpty else {
            panelController.showTemporary(status: "No speech detected", transcript: nil, hideAfter: 1.4)
            insertionAppContext = nil
            status = .idle
            return
        }

        do {
            let insertionResult = try await textInsertionService.insert(
                text: processedText,
                mode: settings.insertionMode,
                targetProcessIdentifier: nil
            )

            switch insertionResult {
            case .inserted:
                AppLogger.shared.log("Text inserted successfully", level: .info)
                onInsertionStatusChanged?("Inserted")
            case .copiedToClipboard:
                AppLogger.shared.log("Clipboard fallback used", level: .warning)
                onInsertionStatusChanged?("Clipboard fallback")
            case .blocked(let reason):
                AppLogger.shared.log("Auto-insert blocked (\(reason)). Clipboard retained for manual paste.", level: .warning)
                onInsertionStatusChanged?("Blocked: \(reason)")
            }

            panelController.showTemporary(status: "Processing", transcript: nil, hideAfter: 0.3)
            insertionAppContext = nil
            status = .idle
        } catch {
            fail(with: error)
        }
    }

    private func ensureSpeechAndMicrophonePermissions() async throws {
        let speechGranted = await permissionsCoordinator.requestSpeechPermissionIfNeeded()

        guard speechGranted else {
            throw VoiceRuntimeError.speechPermissionMissing
        }

        let microphoneGranted = await permissionsCoordinator.requestMicrophonePermissionIfNeeded()

        guard microphoneGranted else {
            throw VoiceRuntimeError.microphonePermissionMissing
        }
    }

    private func fail(with error: Error) {
        let message = error.localizedDescription
        AppLogger.shared.log("Dictation failed: \(message)", level: .error)
        insertionAppContext = nil
        status = .error(message)
        let hideDelay = 1.8
        panelController.showTemporary(status: "Processing", transcript: nil, hideAfter: hideDelay)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(hideDelay + 0.1))
            guard let self else { return }
            if case .error = self.status {
                self.status = .idle
            }
        }
    }

    private func transcriptPreview(_ text: String, maxLength: Int = 320) -> String {
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else {
            return normalized
        }

        let cutoff = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return "\(normalized[..<cutoff])..."
    }
}
