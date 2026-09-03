import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.alexwang.CloseLid", category: "app")

    private var sigtermSource: DispatchSourceSignal?
    /// Swappable for tests/previews; counts other running copies of this bundle id.
    var instances: RunningInstancesCounting = WorkspaceInstances()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.alertPresenter = Self.presentAlert

        // Logged because two copies at different paths are indistinguishable in the
        // menu bar, and knowing which one is running is the first question afterwards.
        Self.log.notice("launched from \(Bundle.main.bundlePath, privacy: .public)")

        if InstanceGuard.shouldStandDown(otherInstances: instances.otherInstanceCount(),
                                         isTesting: InstanceGuard.isRunningTests) {
            // standDown() first: terminate() runs applicationWillTerminate, and the
            // revert in there would switch sleep back on under the copy that owns it.
            AppState.shared.standDown()
            // The alert must finish before the quit, so run it inline here rather than
            // through presentAlert, which defers to the next run-loop turn.
            DispatchQueue.main.async {
                Self.runAlert(title: InstanceGuard.alertTitle, message: InstanceGuard.alertMessage)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        AppState.shared.startPeriodicRefresh()

        // `kill <pid>` / launchd shutdown send SIGTERM, which bypasses willTerminate.
        // Route it through the normal terminate path so the revert still happens.
        // (Force Quit sends SIGKILL and cannot be caught; launch reconciliation covers that.)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.prepareForQuit()
    }

    /// True while an alert is on screen. Blocks a nested `runModal`: a second failure
    /// dispatched to `.main` still runs inside the first alert's modal run loop.
    private static var isPresenting = false

    /// LSUIElement apps have no window to attach to, so activate first and wait one
    /// run-loop turn for the menu to finish dismissing; otherwise the alert opens behind
    /// whatever app has focus. `activate(ignoringOtherApps:)` is a no-op from macOS 14,
    /// which is the deployment target, so the bare `activate()` is what actually works;
    /// the modal-panel level keeps the alert above the frontmost app's windows.
    private static func presentAlert(title: String, message: String) {
        DispatchQueue.main.async { runAlert(title: title, message: message) }
    }

    /// Blocks on the modal; callers that need something to happen *after* the user
    /// dismisses it (the instance guard's quit) call this one directly.
    private static func runAlert(title: String, message: String) {
        guard !isPresenting else { return }   // the menu row still records the error
        isPresenting = true
        defer { isPresenting = false }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.window.level = .modalPanel
        alert.runModal()
    }
}
