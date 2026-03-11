import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "ai.gokul.voice.logger", qos: .utility)
    private let fileManager = FileManager.default
    private let logFileURL: URL

    private init() {
        let preferredLogsDirectory: URL
        if let libraryDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            preferredLogsDirectory = libraryDirectory.appendingPathComponent("Logs/voice", isDirectory: true)
        } else {
            preferredLogsDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("voice-logs", isDirectory: true)
        }

        let fallbackLogsDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("voice-logs", isDirectory: true)
        let logsDirectory = Self.resolveWritableLogsDirectory(
            preferred: preferredLogsDirectory,
            fallback: fallbackLogsDirectory,
            fileManager: fileManager
        )

        logFileURL = logsDirectory.appendingPathComponent("voice.log", isDirectory: false)

        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        log("Logging started at \(ISO8601DateFormatter().string(from: Date()))", level: .info)
    }

    func log(
        _ message: String,
        level: LogLevel = .info,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let source = "\(file):\(line)"
        let entry = "\(timestamp) [\(level.rawValue)] \(source) \(function) - \(message)\n"

        queue.async {
            guard let data = entry.data(using: .utf8) else {
                return
            }

            do {
                let fileHandle = try FileHandle(forWritingTo: self.logFileURL)
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
                try fileHandle.close()
            } catch {
                // Last-resort fallback so logging failures are still visible during development.
                fputs("voice logger error: \(error)\n", stderr)
            }
        }
    }

    func logsDirectoryURL() -> URL {
        logFileURL.deletingLastPathComponent()
    }

    func logFilePath() -> String {
        logFileURL.path
    }

    private static func resolveWritableLogsDirectory(
        preferred: URL,
        fallback: URL,
        fileManager: FileManager
    ) -> URL {
        for candidate in [preferred, fallback] {
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
                let probeURL = candidate.appendingPathComponent(".voice-log-probe", isDirectory: false)
                let writeSucceeded = fileManager.createFile(atPath: probeURL.path, contents: Data("ok".utf8))
                if writeSucceeded {
                    try? fileManager.removeItem(at: probeURL)
                    return candidate
                }
            } catch {
                continue
            }
        }

        return fallback
    }
}
