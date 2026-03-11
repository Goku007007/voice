import AppKit
import ApplicationServices
import Carbon
import Foundation

enum InsertionResult {
    case inserted
    case copiedToClipboard
    case blocked(String)
}

@MainActor
final class TextInsertionService {
    private let focusSettleDelayNanoseconds: UInt64 = 250_000_000
    private let keyUpDelayMicroseconds: useconds_t = 20_000
    private let keyPressDelayNanoseconds: UInt64 = 2_000_000
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["VOICE_DIAGNOSTICS"] == "1"

    private struct FocusedElementContext {
        let hasFocusedElement: Bool
        let role: String?
        let subrole: String?
        let isEditableSurface: Bool
        let isSecureTextInput: Bool
    }

    private enum AppFamily: String {
        case nativeText
        case browser
        case electronCoding
        case terminalLike
        case remoteOrVm
        case other
    }

    private enum InsertionStrategy: String {
        case pasteFirst = "paste-first"
        case typingFallback = "typing-fallback"
    }

    private enum InsertionBlockReason: String {
        case accessibilityNotTrusted = "accessibility_not_trusted"
        case frontmostTargetMissing = "frontmost_target_missing"
        case targetChanged = "target_changed_before_insert"
        case terminalBlocked = "terminal_blocked"
        case highRiskBundleBlocked = "high_risk_bundle_blocked"
        case focusMissing = "focus_missing"
        case secureTextInputBlocked = "secure_text_input_blocked"
        case nonEditableFocus = "non_editable_focus"
        case sensitiveDialogContext = "sensitive_dialog_context"
        case contextChangedBeforeDispatch = "context_changed_before_dispatch"
    }

    func insert(text: String, mode: InsertionMode, targetProcessIdentifier: pid_t?) async throws -> InsertionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .inserted
        }

        if mode == .clipboardOnly {
            copyToClipboard(trimmed)
            AppLogger.shared.log("Insertion mode clipboard-only: text copied to clipboard.", level: .info)
            return .copiedToClipboard
        }

        guard AXIsProcessTrusted() else {
            copyToClipboard(trimmed)
            AppLogger.shared.log("Blocked auto-insert: Accessibility trust missing.", level: .error)
            return .blocked(InsertionBlockReason.accessibilityNotTrusted.rawValue)
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            copyToClipboard(trimmed)
            AppLogger.shared.log("Blocked auto-insert: no frontmost application.", level: .warning)
            return .blocked(InsertionBlockReason.frontmostTargetMissing.rawValue)
        }

        if let providedPid = targetProcessIdentifier,
           providedPid != frontmost.processIdentifier {
            copyToClipboard(trimmed)
            AppLogger.shared.log(
                "Blocked auto-insert: target changed before insertion (capturedPid=\(providedPid), frontmostPid=\(frontmost.processIdentifier)).",
                level: .warning
            )
            return .blocked(InsertionBlockReason.targetChanged.rawValue)
        }

        let targetPid = frontmost.processIdentifier
        let targetBundleId = frontmost.bundleIdentifier
        let appFamily = classifyAppFamily(bundleIdentifier: targetBundleId)

        logInsertionDiagnostics(phase: "insert.start", targetPid: targetPid)

        if let blockedReason = blockedReasonForTargetApp(bundleIdentifier: targetBundleId, appFamily: appFamily) {
            copyToClipboard(trimmed)
            AppLogger.shared.log("Blocked auto-insert by target policy: \(blockedReason.rawValue)", level: .warning)
            return .blocked(blockedReason.rawValue)
        }

        let axManualAccessibilityApplied: Bool
        if appFamily == .electronCoding {
            axManualAccessibilityApplied = enableElectronManualAccessibility(targetPid: targetPid)
        } else {
            axManualAccessibilityApplied = false
        }

        AppLogger.shared.log(
            "Insertion routing appFamily=\(appFamily.rawValue) frontmostBundleId=\(targetBundleId ?? "unknown") axManualAccessibilityApplied=\(axManualAccessibilityApplied)",
            level: .info
        )

        let initialFocus = focusedElementContext(for: targetPid, appFamily: appFamily)
        AppLogger.shared.log(
            "Focused AX role=\(initialFocus.role ?? "none") subrole=\(initialFocus.subrole ?? "none") editable=\(initialFocus.isEditableSurface)",
            level: .info
        )

        if let blockedReason = blockedReasonForFocus(initialFocus) {
            copyToClipboard(trimmed)
            AppLogger.shared.log("Blocked auto-insert by focused-context policy: \(blockedReason.rawValue)", level: .warning)
            return .blocked(blockedReason.rawValue)
        }

        let strategy = selectStrategy(appFamily: appFamily)
        AppLogger.shared.log("Insertion strategy selected: \(strategy.rawValue)", level: .info)

        copyToClipboard(trimmed)

        guard AXIsProcessTrusted(), isTargetFrontmost(targetPid) else {
            AppLogger.shared.log("Blocked auto-insert: trust/frontmost changed before dispatch.", level: .warning)
            return .blocked(InsertionBlockReason.contextChangedBeforeDispatch.rawValue)
        }

        try? await Task.sleep(nanoseconds: focusSettleDelayNanoseconds)

        guard AXIsProcessTrusted(), isTargetFrontmost(targetPid) else {
            AppLogger.shared.log("Blocked auto-insert: trust/frontmost changed during settle delay.", level: .warning)
            return .blocked(InsertionBlockReason.contextChangedBeforeDispatch.rawValue)
        }

        let finalFocus = focusedElementContext(for: targetPid, appFamily: appFamily)
        if let blockedReason = blockedReasonForFocus(finalFocus) {
            AppLogger.shared.log("Blocked auto-insert after final focus re-check: \(blockedReason.rawValue)", level: .warning)
            return .blocked(blockedReason.rawValue)
        }

        switch strategy {
        case .pasteFirst:
            if postCommandVToEventStream() {
                return .inserted
            }

            AppLogger.shared.log("Paste dispatch failed at event construction; attempting typing fallback.", level: .warning)
            let typed = await simulateTyping(text: trimmed, targetPid: targetPid)
            if typed {
                return .inserted
            }
            return .copiedToClipboard

        case .typingFallback:
            let typed = await simulateTyping(text: trimmed, targetPid: targetPid)
            if typed {
                return .inserted
            }
            return .copiedToClipboard
        }
    }

    private func classifyAppFamily(bundleIdentifier: String?) -> AppFamily {
        guard let bundleIdentifier else {
            return .other
        }

        let normalized = bundleIdentifier.lowercased()

        let browserBundleIds: Set<String> = [
            "com.apple.safari",
            "com.google.chrome",
            "com.google.chrome.canary",
            "org.mozilla.firefox",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "com.operasoftware.opera",
            "com.vivaldi.vivaldi",
            "company.thebrowser.browser"
        ]
        if browserBundleIds.contains(normalized) {
            return .browser
        }

        let electronCodingBundleIds: Set<String> = [
            "com.microsoft.vscode",
            "com.microsoft.vscodeinsiders",
            "com.vscodium",
            "com.todesktop.230313mzl4w4u92",
            "com.exafunction.windsurf"
        ]
        if electronCodingBundleIds.contains(normalized)
            || normalized.contains("vscode")
            || normalized.contains("cursor")
            || normalized.contains("windsurf") {
            return .electronCoding
        }

        let terminalBundleIds: Set<String> = [
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "dev.warp.warp-stable"
        ]
        if terminalBundleIds.contains(normalized) {
            return .terminalLike
        }

        let remoteOrVmBundleIds: Set<String> = [
            "com.microsoft.rdc.macos",
            "com.teamviewer.teamviewer",
            "com.realvnc.vncviewer",
            "com.parallels.desktop.console",
            "org.virtualbox.app.virtualbox"
        ]
        if remoteOrVmBundleIds.contains(normalized) {
            return .remoteOrVm
        }

        if normalized.hasPrefix("com.apple.") {
            return .nativeText
        }

        return .other
    }

    private func selectStrategy(appFamily: AppFamily) -> InsertionStrategy {
        switch appFamily {
        case .nativeText, .browser, .electronCoding, .other:
            return .pasteFirst
        case .terminalLike, .remoteOrVm:
            return .typingFallback
        }
    }

    private func blockedReasonForTargetApp(bundleIdentifier: String?, appFamily: AppFamily) -> InsertionBlockReason? {
        if appFamily == .terminalLike {
            return .terminalBlocked
        }

        if appFamily == .remoteOrVm {
            return .highRiskBundleBlocked
        }

        guard let bundleIdentifier else {
            return nil
        }

        let blockedBundleIds: Set<String> = [
            "com.apple.systempreferences",
            "com.apple.systemsettings",
            "com.apple.securityagent",
            "com.apple.loginwindow",
            "com.apple.finder"
        ]

        let normalized = bundleIdentifier.lowercased()
        if blockedBundleIds.contains(normalized) {
            return .highRiskBundleBlocked
        }

        return nil
    }

    private func blockedReasonForFocus(_ context: FocusedElementContext) -> InsertionBlockReason? {
        if !context.hasFocusedElement {
            return .focusMissing
        }

        if context.isSecureTextInput {
            return .secureTextInputBlocked
        }

        let sensitiveContainerRoles: Set<String> = [
            "AXDialog",
            "AXSheet",
            "AXPopover",
            "AXSystemDialog"
        ]
        if let role = context.role, sensitiveContainerRoles.contains(role) {
            return .sensitiveDialogContext
        }

        if !context.isEditableSurface {
            return .nonEditableFocus
        }

        return nil
    }

    private func focusedElementContext(for targetPid: pid_t, appFamily: AppFamily) -> FocusedElementContext {
        let appElement = AXUIElementCreateApplication(targetPid)
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedError == .success, let focusedValue else {
            if diagnosticsEnabled {
                AppLogger.shared.log(
                    "Focused element lookup failed (AXError=\(focusedError.rawValue)).",
                    level: .debug
                )
            }
            return FocusedElementContext(
                hasFocusedElement: false,
                role: nil,
                subrole: nil,
                isEditableSurface: false,
                isSecureTextInput: false
            )
        }

        let focusedElement = focusedValue as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute as String, for: focusedElement)
        let subrole = stringAttribute(kAXSubroleAttribute as String, for: focusedElement)
        let editableAttribute = boolAttribute("AXEditable", for: focusedElement) ?? false

        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXTextView",
            "AXComboBox",
            "AXSearchField"
        ]

        let webEditorRoles: Set<String> = [
            "AXWebArea",
            "AXDocument"
        ]

        let isEditableByRole = role.map { editableRoles.contains($0) } ?? false
        let supportsWebEditorRole = role.map { webEditorRoles.contains($0) } ?? false
        let isBrowserLike = appFamily == .browser || appFamily == .electronCoding
        let isEditableSurface = editableAttribute || isEditableByRole || (isBrowserLike && supportsWebEditorRole)

        let secureRole = role == "AXSecureTextField"
        let secureSubrole = subrole == "AXSecureTextField"
        let isSecureTextInput = secureRole || secureSubrole

        return FocusedElementContext(
            hasFocusedElement: true,
            role: role,
            subrole: subrole,
            isEditableSurface: isEditableSurface,
            isSecureTextInput: isSecureTextInput
        )
    }

    private func stringAttribute(_ attribute: String, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        if let stringValue = value as? String {
            return stringValue
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    private func boolAttribute(_ attribute: String, for element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return (value as? NSNumber)?.boolValue ?? (value as? Bool)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrote = pasteboard.writeObjects([text as NSString])
        if !wrote {
            _ = pasteboard.setString(text, forType: .string)
        }
        AppLogger.shared.log("Clipboard updated with \(text.count) characters", level: .debug)
    }

    private func isTargetFrontmost(_ targetPid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid
    }

    private func enableElectronManualAccessibility(targetPid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(targetPid)
        let result = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        if result == .success {
            return true
        }

        AppLogger.shared.log(
            "AXManualAccessibility enable failed for pid \(targetPid) with AXError=\(result.rawValue)",
            level: .warning
        )
        return false
    }

    private func postCommandVToEventStream() -> Bool {
        guard AXIsProcessTrusted() else {
            AppLogger.shared.log("Blocked Cmd+V dispatch: accessibility trust no longer granted.", level: .warning)
            return false
        }

        let vKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            AppLogger.shared.log("Failed to create CGEventSource for Cmd+V.", level: .error)
            return false
        }

        guard let cmdVDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            AppLogger.shared.log("Failed to create Cmd+V key events.", level: .error)
            return false
        }

        cmdVDown.flags = .maskCommand
        cmdVUp.flags = .maskCommand

        cmdVDown.post(tap: .cghidEventTap)
        usleep(keyUpDelayMicroseconds)
        cmdVUp.post(tap: .cghidEventTap)
        return true
    }

    private func simulateTyping(text: String, targetPid: pid_t) async -> Bool {
        guard AXIsProcessTrusted() else {
            AppLogger.shared.log("Blocked typing fallback: accessibility trust no longer granted.", level: .warning)
            return false
        }

        guard isTargetFrontmost(targetPid) else {
            AppLogger.shared.log("Blocked typing fallback: target app is no longer frontmost.", level: .warning)
            return false
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            AppLogger.shared.log("Failed to create CGEventSource for typed fallback.", level: .error)
            return false
        }

        for scalar in text.utf16 {
            if !AXIsProcessTrusted() || !isTargetFrontmost(targetPid) {
                AppLogger.shared.log("Aborting typing fallback due to trust/frontmost change.", level: .warning)
                return false
            }

            let character = [UniChar(scalar)]
            guard let eventDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let eventUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }

            eventDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: character)
            eventUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: character)
            eventDown.post(tap: .cghidEventTap)
            eventUp.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: keyPressDelayNanoseconds)
        }

        return true
    }

    private func logInsertionDiagnostics(phase: String, targetPid: pid_t) {
        let targetApplication = NSRunningApplication(processIdentifier: targetPid)
        let targetBundleId = targetApplication?.bundleIdentifier ?? "unknown"
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostBundleId = frontmost?.bundleIdentifier ?? "none"
        let frontmostPid = frontmost?.processIdentifier ?? 0
        let message = "Diagnostics[\(phase)] targetBundleId=\(targetBundleId) targetPid=\(targetPid) frontmostBundleId=\(frontmostBundleId) frontmostPid=\(frontmostPid)"
        AppLogger.shared.log(message, level: diagnosticsEnabled ? .info : .debug)
    }
}
