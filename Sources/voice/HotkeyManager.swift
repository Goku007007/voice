import AppKit
import Carbon
import Foundation

@MainActor
final class HotkeyManager {
    var onToggle: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnIsDown = false
    private var lastToggleTime: Date = .distantPast
    private let debounceDuration: TimeInterval = 0.25

    // Shared static reference for the Carbon callback
    fileprivate static var activeInstance: HotkeyManager?

    func start() {
        HotkeyManager.activeInstance = self

        // Primary: Carbon ⌥Space (proven reliable, works globally)
        registerCarbonHotkey()

        // Secondary: fn key via NSEvent monitors (best-effort)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        AppLogger.shared.log("HotkeyManager: started (⌥Space + fn)", level: .info)
    }

    func stop() {
        unregisterCarbonHotkey()

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        HotkeyManager.activeInstance = nil
        AppLogger.shared.log("HotkeyManager: stopped", level: .info)
    }

    // MARK: - Carbon Hotkey (⌥Space)

    private func registerCarbonHotkey() {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("VOIC"), id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            1,
            &eventType,
            nil,
            nil
        )

        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            AppLogger.shared.log("HotkeyManager: ⌥Space registered", level: .info)
        } else {
            AppLogger.shared.log("HotkeyManager: ⌥Space registration failed (status: \(status))", level: .error)
        }
    }

    private func unregisterCarbonHotkey() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
    }

    fileprivate func handleCarbonHotkey() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) >= debounceDuration else {
            return
        }
        lastToggleTime = now
        AppLogger.shared.log("HotkeyManager: ⌥Space triggered", level: .debug)
        onToggle?()
    }

    // MARK: - fn Key (best-effort secondary)

    private func handleFlagsChanged(_ event: NSEvent) {
        let fnPressed = event.modifierFlags.contains(.function)

        // Only fire on fn-only (no other modifiers)
        let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let hasOtherModifiers = !event.modifierFlags.intersection(otherModifiers).isEmpty

        if fnPressed && !fnIsDown && !hasOtherModifiers {
            fnIsDown = true

            let now = Date()
            guard now.timeIntervalSince(lastToggleTime) >= debounceDuration else {
                AppLogger.shared.log("HotkeyManager: fn debounced", level: .debug)
                return
            }
            lastToggleTime = now

            AppLogger.shared.log("HotkeyManager: fn triggered", level: .debug)
            onToggle?()
        } else if !fnPressed && fnIsDown {
            fnIsDown = false
        }
    }
}

// MARK: - Carbon Callback (free function)

private func carbonHotkeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    Task { @MainActor in
        HotkeyManager.activeInstance?.handleCarbonHotkey()
    }
    return noErr
}

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) + FourCharCode(char)
    }
    return result
}
