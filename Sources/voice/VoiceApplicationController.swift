import AppKit
import Foundation

@MainActor
final class VoiceApplicationController: NSObject {
    private let settingsStore = SettingsStore()
    private let permissionsCoordinator = PermissionsCoordinator()
    private let transcriptionEngine = SpeechRecognizerService()
    private let textInsertionService = TextInsertionService()
    private let panelController = FloatingStatusPanelController()
    private let hotkeyManager = HotkeyManager()
    private let cleanupService: TranscriptCleanupService = BasicCleanupService()
    private lazy var settingsWindowController = SettingsWindowController(settingsStore: settingsStore)

    private lazy var dictationController = DictationController(
        settingsStore: settingsStore,
        permissionsCoordinator: permissionsCoordinator,
        transcriptionEngine: transcriptionEngine,
        textInsertionService: textInsertionService,
        panelController: panelController,
        cleanupService: cleanupService
    )

    private var statusItem: NSStatusItem?
    private weak var toggleMenuItem: NSMenuItem?
    private weak var accessibilityStatusMenuItem: NSMenuItem?
    private weak var insertionStatusMenuItem: NSMenuItem?
    private weak var insertionProbeMenuItem: NSMenuItem?
    private var accessibilityTrusted = false
    private var hasShownAccessibilityGuidanceThisLaunch = false
    private var accessibilityTrustPollTimer: Timer?

    func start() {
        AppLogger.shared.log("voice app start")
        AppLogger.shared.log("Log file: \(AppLogger.shared.logFilePath())")
        AppLogger.shared.log("Transcription engine: \(transcriptionEngine.engineName)")
        transcriptionEngine.warmUpLanguageAssets()
        logEnvironmentDiagnostics(reason: "startup")
        configureMenuBarItem()
        wireEvents()
        requestInitialPermissions()
        showFirstLaunchGuideIfNeeded()

        panelController.showTemporary(
            status: "voice ready",
            transcript: "Press ⌥Space or fn to dictate.",
            hideAfter: 2.2
        )
    }

    func stop() {
        AppLogger.shared.log("voice app stop")
        stopAccessibilityTrustPolling()
        dictationController.stopIfNeeded()
        hotkeyManager.stop()
    }

    private func wireEvents() {
        dictationController.onStatusChanged = { [weak self] status in
            self?.updateMenuBar(for: status)
        }

        dictationController.onInsertionStatusChanged = { [weak self] status in
            self?.updateInsertionStatusMenu(status)
        }

        settingsStore.onChange = { [weak self] settings in
            guard let self else {
                return
            }

            AppLogger.shared.log(
                "Settings updated: recordingMode=\(settings.recordingMode.rawValue), profile=\(settings.transcriptionProfile.rawValue), insertion=\(settings.insertionMode.rawValue)",
                level: .debug
            )
            self.updateMenuBar(for: self.dictationController.status)
        }

        hotkeyManager.onToggle = { [weak self] in
            Task { @MainActor in
                self?.dictationController.handleHotkeyPressed()
            }
        }

        hotkeyManager.start()
        AppLogger.shared.log("Global hotkey registered (fn)")
    }

    private func requestInitialPermissions() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let trusted = self.refreshAccessibilityTrust(prompt: true, reason: "startup")
            if !trusted {
                self.showAccessibilityNotGrantedStatus()
                self.showAccessibilityGuidanceIfNeeded()
            }

            if !self.permissionsCoordinator.isSpeechPermissionGranted()
                || !self.permissionsCoordinator.isMicrophonePermissionGranted() {
                AppLogger.shared.log("Mic/Speech permissions not yet granted", level: .warning)
            }
        }
    }

    private func showFirstLaunchGuideIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "voice.hasShownFirstLaunchGuide"
        guard !defaults.bool(forKey: key) else {
            return
        }

        defaults.set(true, forKey: key)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "voice is running"
            alert.informativeText = """
            Use ⌥Space or fn to dictate.
            Enable Microphone, Speech Recognition, and Accessibility when prompted.
            Text will paste at your cursor when possible, then fall back to simulated typing or clipboard.
            """
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func configureMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusItem(title: "voice", toolTip: "voice")

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: startMenuTitle(),
            action: #selector(toggleDictationFromMenu),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        self.toggleMenuItem = toggleItem

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let accessibilityStatusItem = NSMenuItem(title: "Accessibility: Checking...", action: nil, keyEquivalent: "")
        accessibilityStatusItem.isEnabled = false
        menu.addItem(accessibilityStatusItem)
        self.accessibilityStatusMenuItem = accessibilityStatusItem

        let insertionStatusItem = NSMenuItem(title: "Insertion: No recent action", action: nil, keyEquivalent: "")
        insertionStatusItem.isEnabled = false
        menu.addItem(insertionStatusItem)
        self.insertionStatusMenuItem = insertionStatusItem

        menu.addItem(.separator())
        let accessibilityItem = NSMenuItem(
            title: "Grant Accessibility Access",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let recheckAccessibilityItem = NSMenuItem(
            title: "Re-check Accessibility Status",
            action: #selector(recheckAccessibilityStatus),
            keyEquivalent: ""
        )
        recheckAccessibilityItem.target = self
        menu.addItem(recheckAccessibilityItem)

        let openAccessibilitySettingsItem = NSMenuItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettingsFromMenu),
            keyEquivalent: ""
        )
        openAccessibilitySettingsItem.target = self
        menu.addItem(openAccessibilitySettingsItem)


        let permissionItem = NSMenuItem(
            title: "Request Mic/Speech Permissions",
            action: #selector(requestMicrophoneAndSpeechPermissions),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        let logsItem = NSMenuItem(
            title: "Open Logs Folder",
            action: #selector(openLogsFolder),
            keyEquivalent: ""
        )
        logsItem.target = self
        menu.addItem(logsItem)

        let diagnosticsItem = NSMenuItem(
            title: "Log Environment Diagnostics",
            action: #selector(logEnvironmentDiagnosticsFromMenu),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        let insertionProbeItem = NSMenuItem(
            title: "Run Notes/TextEdit Insertion Probe",
            action: #selector(runInsertionProbe),
            keyEquivalent: ""
        )
        insertionProbeItem.target = self
        menu.addItem(insertionProbeItem)
        self.insertionProbeMenuItem = insertionProbeItem

        let tccCommandItem = NSMenuItem(
            title: "Copy TCC Log Command",
            action: #selector(copyTCCLogCommand),
            keyEquivalent: ""
        )
        tccCommandItem.target = self
        menu.addItem(tccCommandItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit voice", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        updateAccessibilityPermissionUI()
    }

    private func updateMenuBar(for status: VoiceStatus) {
        guard accessibilityTrusted else {
            setStatusItem(title: "voice !", toolTip: "voice: Accessibility not granted")
            toggleMenuItem?.title = "Start Dictation (Accessibility not granted)"
            return
        }

        let startTitle = startMenuTitle()
        let stopTitle = stopMenuTitle()

        switch status {
        case .idle:
            setStatusItem(title: "voice", toolTip: "voice: Ready")
            toggleMenuItem?.title = startTitle
        case .listening:
            setStatusItem(title: "voice ●", toolTip: "voice: Listening")
            toggleMenuItem?.title = stopTitle
        case .processing:
            setStatusItem(title: "voice …", toolTip: "voice: Processing")
            toggleMenuItem?.title = "Processing..."
        case .error:
            setStatusItem(title: "voice !", toolTip: "voice: Error")
            toggleMenuItem?.title = startTitle
        }
    }

    private func setStatusItem(title: String, toolTip: String) {
        statusItem?.button?.image = nil
        statusItem?.button?.title = title
        statusItem?.button?.toolTip = toolTip
    }

    private func startMenuTitle() -> String {
        "Start Dictation (⌥Space / fn)"
    }

    private func stopMenuTitle() -> String {
        "Stop Dictation (⌥Space / fn)"
    }

    @objc
    private func toggleDictationFromMenu() {
        AppLogger.shared.log("Menu action: toggle dictation")
        dictationController.toggleDictation()
    }
    @objc
    private func requestAccessibilityPermission() {
        let trusted = refreshAccessibilityTrust(prompt: true, reason: "manualPrompt")
        AppLogger.shared.log("Accessibility permission requested (trusted=\(trusted))")
        if !trusted {
            showAccessibilityNotGrantedStatus()
            _ = openAccessibilitySettings()
            showAccessibilityGuidanceIfNeeded()
        }
    }

    @objc
    private func recheckAccessibilityStatus() {
        let trusted = refreshAccessibilityTrust(prompt: false, reason: "manualRecheck")
        if trusted {
            panelController.showTemporary(
                status: "Accessibility granted",
                transcript: "Insertion tests enabled.",
                hideAfter: 1.6
            )
        } else {
            showAccessibilityNotGrantedStatus()
        }
    }

    @objc
    private func openAccessibilitySettingsFromMenu() {
        if !openAccessibilitySettings() {
            showAccessibilityGuidanceIfNeeded()
        }
    }


    @objc
    private func requestMicrophoneAndSpeechPermissions() {
        Task { @MainActor in
            AppLogger.shared.log("Mic/Speech permission request triggered")
            await permissionsCoordinator.requestSpeechAndMicrophonePermissions()
        }
    }

    @objc
    private func openSettings() {
        AppLogger.shared.log("Settings opened")
        settingsWindowController.present()
    }

    @objc
    private func openLogsFolder() {
        let logsURL = AppLogger.shared.logsDirectoryURL()
        NSWorkspace.shared.open(logsURL)
        AppLogger.shared.log("Opened logs folder: \(logsURL.path)")
    }

    @objc
    private func logEnvironmentDiagnosticsFromMenu() {
        logEnvironmentDiagnostics(reason: "menu")
    }

    @objc
    private func runInsertionProbe() {
        guard refreshAccessibilityTrust(prompt: false, reason: "probeCheck", logDiagnostics: false) else {
            AppLogger.shared.log("Insertion probe blocked: Accessibility not granted.", level: .warning)
            showAccessibilityNotGrantedStatus()
            return
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            AppLogger.shared.log("Insertion probe skipped: no frontmost app.", level: .warning)
            return
        }

        let bundleId = frontmost.bundleIdentifier ?? "unknown"
        let isKnownGoodTarget = bundleId == "com.apple.TextEdit" || bundleId == "com.apple.Notes"
        guard isKnownGoodTarget else {
            AppLogger.shared.log(
                "Insertion probe skipped: frontmost app is \(bundleId). Switch to Notes or TextEdit and rerun.",
                level: .warning
            )
            panelController.showTemporary(
                status: "Probe requires Notes/TextEdit",
                transcript: nil,
                hideAfter: 1.6
            )
            return
        }

        let probeText = "[voice probe] If you see this, synthetic insertion reached \(bundleId)."
        Task { @MainActor in
            do {
                let result = try await textInsertionService.insert(
                    text: probeText,
                    mode: .directPaste,
                    targetProcessIdentifier: frontmost.processIdentifier
                )
                AppLogger.shared.log(
                    "Insertion probe dispatched to \(bundleId) pid=\(frontmost.processIdentifier) result=\(result)",
                    level: .info
                )

                switch result {
                case .inserted:
                    updateInsertionStatusMenu("Probe inserted")
                    panelController.showTemporary(
                        status: "Probe inserted",
                        transcript: "Check the active editor for probe text.",
                        hideAfter: 1.8
                    )
                case .copiedToClipboard:
                    updateInsertionStatusMenu("Probe clipboard fallback")
                    panelController.showTemporary(
                        status: "Probe copied only",
                        transcript: "Auto-insert unavailable; paste manually.",
                        hideAfter: 1.8
                    )
                case .blocked(let reason):
                    updateInsertionStatusMenu("Probe blocked: \(reason)")
                    panelController.showTemporary(
                        status: "Probe blocked",
                        transcript: reason,
                        hideAfter: 1.8
                    )
                }
            } catch {
                AppLogger.shared.log("Insertion probe failed: \(error.localizedDescription)", level: .error)
                panelController.showTemporary(
                    status: "Probe failed",
                    transcript: "See logs for details.",
                    hideAfter: 1.6
                )
            }
        }
    }

    private func updateInsertionStatusMenu(_ status: String) {
        let normalized = status.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped: String
        if normalized.count > 96 {
            clipped = String(normalized.prefix(96)) + "…"
        } else {
            clipped = normalized
        }
        insertionStatusMenuItem?.title = "Insertion: \(clipped)"
    }

    @objc
    private func copyTCCLogCommand() {
        let command = tccLogCommand()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        AppLogger.shared.log("Copied TCC log command to clipboard: \(command)", level: .info)
        panelController.showTemporary(
            status: "Copied TCC command",
            transcript: nil,
            hideAfter: 1.4
        )
    }

    private func logEnvironmentDiagnostics(reason: String) {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executableURL?.path ?? "unknown"
        let lsuiElementRaw = Bundle.main.object(forInfoDictionaryKey: "LSUIElement")
        let isLSUIElement = parseInfoPlistBool(lsuiElementRaw)
        let axTrusted = permissionsCoordinator.isAccessibilityTrusted(prompt: false)
        let appIsActive = NSApp.isActive
        let activationPolicy = activationPolicyDescription(NSApp.activationPolicy())
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostBundleId = frontmost?.bundleIdentifier ?? "none"
        let frontmostPid = frontmost?.processIdentifier ?? 0
        let frontmostName = frontmost?.localizedName ?? "none"

        AppLogger.shared.log(
            "Diagnostics[\(reason)] bundleId=\(bundleId) bundlePath=\(bundlePath) executablePath=\(executablePath) lsuiElement=\(isLSUIElement) activationPolicy=\(activationPolicy) appIsActive=\(appIsActive) axTrusted=\(axTrusted) frontmostBundleId=\(frontmostBundleId) frontmostName=\(frontmostName) frontmostPid=\(frontmostPid)",
            level: .info
        )
        AppLogger.shared.log(
            "Diagnostics[\(reason)] TCC stream command: \(tccLogCommand())",
            level: .info
        )
    }

    private func refreshAccessibilityTrust(prompt: Bool, reason: String, logDiagnostics: Bool = true) -> Bool {
        let trusted = permissionsCoordinator.isAccessibilityTrusted(prompt: prompt)
        let changed = trusted != accessibilityTrusted
        accessibilityTrusted = trusted
        updateAccessibilityPermissionUI()

        if trusted {
            stopAccessibilityTrustPolling()
        } else {
            startAccessibilityTrustPollingIfNeeded()
        }

        if changed {
            AppLogger.shared.log("Accessibility trust changed (\(reason)): \(trusted)", level: .info)
        }
        if logDiagnostics {
            logEnvironmentDiagnostics(reason: "accessibility.\(reason)")
        }

        return trusted
    }

    private func updateAccessibilityPermissionUI() {
        accessibilityStatusMenuItem?.title = accessibilityTrusted
            ? "Accessibility: Granted"
            : "Accessibility: Not Granted"
        insertionProbeMenuItem?.isEnabled = accessibilityTrusted
        updateMenuBar(for: dictationController.status)
    }

    private func startAccessibilityTrustPollingIfNeeded() {
        guard accessibilityTrustPollTimer == nil else {
            return
        }

        accessibilityTrustPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let trusted = self.permissionsCoordinator.isAccessibilityTrusted(prompt: false)
                if trusted != self.accessibilityTrusted {
                    _ = self.refreshAccessibilityTrust(prompt: false, reason: "poll")
                    if trusted {
                        self.panelController.showTemporary(
                            status: "Accessibility granted",
                            transcript: "Insertion tests enabled.",
                            hideAfter: 1.6
                        )
                    }
                }
            }
        }
        RunLoop.main.add(accessibilityTrustPollTimer!, forMode: .common)
    }

    private func stopAccessibilityTrustPolling() {
        accessibilityTrustPollTimer?.invalidate()
        accessibilityTrustPollTimer = nil
    }

    private func showAccessibilityNotGrantedStatus() {
        panelController.showTemporary(
            status: "Accessibility not granted",
            transcript: "System Settings > Privacy & Security > Accessibility",
            hideAfter: 2.2
        )
    }

    private func showAccessibilityGuidanceIfNeeded() {
        guard !accessibilityTrusted, !hasShownAccessibilityGuidanceThisLaunch else {
            return
        }
        hasShownAccessibilityGuidanceThisLaunch = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility not granted"
        alert.informativeText = """
        Enable voice in System Settings > Privacy & Security > Accessibility.
        Auto-paste and auto-typing stay disabled until trust is granted.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            _ = openAccessibilitySettings()
        }
    }

    private func openAccessibilitySettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                AppLogger.shared.log("Opened Accessibility settings URL: \(candidate)", level: .info)
                return true
            }
        }

        AppLogger.shared.log(
            "Could not open Accessibility settings URL. Guide user to System Settings > Privacy & Security > Accessibility.",
            level: .warning
        )
        return false
    }

    private func tccLogCommand() -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.voice.app"
        return "log stream --debug --predicate 'subsystem == \"com.apple.TCC\" AND eventMessage CONTAINS \"\(bundleId)\"'"
    }

    private func parseInfoPlistBool(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let stringValue = value as? String {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return false
    }

    private func activationPolicyDescription(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown"
        }
    }

    @objc
    private func quitApplication() {
        NSApp.terminate(nil)
    }
}
