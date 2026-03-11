import Foundation

enum CleanupMode: String, CaseIterable {
    case basic

    var title: String {
        switch self {
        case .basic:
            return "Basic (Regex Only)"
        }
    }

    var description: String {
        switch self {
        case .basic:
            return "Fast regex cleanup: filler removal, capitalization, punctuation."
        }
    }
}

@MainActor
protocol TranscriptCleanupService {
    func clean(_ text: String, settings: AppSettings, appContext: AppContext?) async -> String
}

struct AppContext {
    let bundleIdentifier: String?
    let appName: String?

    var toneHint: String {
        guard let bundleID = bundleIdentifier?.lowercased() else {
            return "neutral"
        }

        if bundleID.contains("slack") || bundleID.contains("whatsapp")
            || bundleID.contains("telegram") || bundleID.contains("messages")
            || bundleID.contains("discord") {
            return "casual"
        }

        if bundleID.contains("mail") || bundleID.contains("outlook")
            || bundleID.contains("gmail") {
            return "professional"
        }

        if bundleID.contains("xcode") || bundleID.contains("vscode")
            || bundleID.contains("cursor") || bundleID.contains("terminal")
            || bundleID.contains("iterm") || bundleID.contains("warp")
            || bundleID.contains("windsurf") {
            return "technical"
        }

        return "neutral"
    }
}
