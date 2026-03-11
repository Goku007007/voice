import AppKit

final class VoiceAppDelegate: NSObject, NSApplicationDelegate {
    private var applicationController: VoiceApplicationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applicationController = VoiceApplicationController()
        applicationController?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        applicationController?.stop()
    }
}
