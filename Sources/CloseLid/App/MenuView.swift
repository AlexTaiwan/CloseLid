import SwiftUI

/// Menu layout (from the design review). Rows in `.menu` style are plain AppKit menu
/// items: `Text` draws disabled, `Toggle` draws a real checkmark item.
///
///   [last error, if any]                          (disabled)
///   ✓ Keep Awake with Lid Closed                   Toggle; disabled when unknown or rule missing
///   Could not read the sleep setting               (disabled; unknown only)
///   Not set up yet — needs a one-time admin password   (disabled; rule missing only)
///   Install Sudoers Rule…                          (rule missing only)
///   ─────
///   On AC power | On battery — Keep Awake will run it down to empty | Power source unknown
///   ─────
///   Launch at Login                                Toggle
///   Approve CloseLid under System Settings › Login Items   (disabled; requiresApproval only)
///   Stay Awake After Quit                          Toggle
///   Remove Sudoers Rule…                           (rule installed only)
///   ─────
///   Quit CloseLid                              ⌘Q
struct MenuView: View {
    @Bindable var state: AppState

    var body: some View {
        if let error = state.lastError {
            Text(error)
        }

        Toggle("Keep Awake with Lid Closed", isOn: Binding(
            get: { state.mode == .awake },
            set: { _ in state.toggle() }
        ))
        .disabled(state.mode == .unknown || !state.helperInstalled)

        if state.mode == .unknown {
            Text("Could not read the sleep setting")
        }
        if !state.helperInstalled {
            Text("Not set up yet — needs a one-time admin password")
            Button("Install Sudoers Rule…", action: state.installHelper)
        }

        Divider()

        Text(powerLine)

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { state.launchAtLogin == .enabled },
            set: { state.setLaunchAtLogin($0) }
        ))
        if state.launchAtLogin == .requiresApproval {
            Text("Approve CloseLid under System Settings › Login Items")
        }
        Toggle("Stay Awake After Quit", isOn: $state.stayAwakeAfterQuit)
        if state.helperInstalled {
            Button("Remove Sudoers Rule…", action: state.removeHelper)
        }

        Divider()

        Button("Quit CloseLid") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var powerLine: String {
        switch state.powerSource {
        case .ac:      return "On AC power"
        case .battery: return "On battery — Keep Awake will run it down to empty"
        case .unknown: return "Power source unknown"
        }
    }
}
