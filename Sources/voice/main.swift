import AppKit
import CoreGraphics
import Foundation

private func isInteractiveGUISession() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }

    if let onConsole = session["kCGSessionOnConsoleKey"] as? Bool {
        return onConsole
    }

    return true
}

if !isInteractiveGUISession() {
    let message = "voice requires an interactive GUI session. Launch from Finder or a local Terminal session."
    fputs("voice: \(message)\n", stderr)
    AppLogger.shared.log(message, level: .error)
    exit(78)
}

let app = NSApplication.shared
let delegate = VoiceAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
