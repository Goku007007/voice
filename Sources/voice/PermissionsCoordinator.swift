import ApplicationServices
import AVFoundation
import Foundation
import Speech

@MainActor
final class PermissionsCoordinator {
    private var hasRequestedSpeechThisLaunch = false
    private var hasRequestedMicrophoneThisLaunch = false

    func requestSpeechAndMicrophonePermissions() async {
        _ = await requestSpeechPermissionIfNeeded()
        _ = await requestMicrophonePermissionIfNeeded()
    }

    func requestSpeechPermission() async -> Bool {
        let status = await PermissionRequestBridge.requestSpeechAuthorizationStatus()
        hasRequestedSpeechThisLaunch = true
        AppLogger.shared.log("Speech permission status: \(status.rawValue)")
        return status == .authorized
    }

    func requestMicrophonePermission() async -> Bool {
        let granted = await PermissionRequestBridge.requestMicrophoneAccess()
        hasRequestedMicrophoneThisLaunch = true
        AppLogger.shared.log("Microphone permission granted: \(granted)")
        return granted
    }

    func isSpeechPermissionGranted() -> Bool {
        speechAuthorizationStatus() == .authorized
    }

    func isMicrophonePermissionGranted() -> Bool {
        microphoneAuthorizationStatus() == .authorized
    }

    func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestSpeechPermissionIfNeeded() async -> Bool {
        let status = speechAuthorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard !hasRequestedSpeechThisLaunch else {
                AppLogger.shared.log("Speech permission prompt already attempted this launch; skipping repeat prompt.", level: .warning)
                return false
            }
            return await requestSpeechPermission()
        case .denied, .restricted:
            AppLogger.shared.log("Speech permission denied/restricted; prompt not repeated automatically.", level: .warning)
            return false
        @unknown default:
            AppLogger.shared.log("Speech permission unknown status \(status.rawValue); treating as not granted.", level: .warning)
            return false
        }
    }

    func requestMicrophonePermissionIfNeeded() async -> Bool {
        let status = microphoneAuthorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard !hasRequestedMicrophoneThisLaunch else {
                AppLogger.shared.log("Microphone permission prompt already attempted this launch; skipping repeat prompt.", level: .warning)
                return false
            }
            return await requestMicrophonePermission()
        case .denied, .restricted:
            AppLogger.shared.log("Microphone permission denied/restricted; prompt not repeated automatically.", level: .warning)
            return false
        @unknown default:
            AppLogger.shared.log("Microphone permission unknown status \(status.rawValue); treating as not granted.", level: .warning)
            return false
        }
    }



    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt" as CFString: prompt
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }
}

private enum PermissionRequestBridge {
    static func requestSpeechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
