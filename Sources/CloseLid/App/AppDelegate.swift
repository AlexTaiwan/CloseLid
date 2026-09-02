import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.alertPresenter = Self.presentAlert
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

    /// LSUIElement apps have no window to attach to, so activate first and wait one
    /// run-loop turn for the menu to finish dismissing; otherwise the alert opens behind
    /// whatever app has focus.
    private static func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
