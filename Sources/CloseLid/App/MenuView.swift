import SwiftUI

/// Menu layout (from the design review). Rows in `.menu` style are plain AppKit menu
/// items: `Text` draws disabled, `Toggle` draws a real checkmark item.
///
///   [last error, if any]                          (disabled)
///   Keep Awake switched itself off at 10% battery  (disabled; after the battery guard fired)
///   ✓ Keep Awake with Lid Closed                   Toggle; disabled when unknown or rule missing
///   Could not read the sleep setting               (disabled; unknown only)
///   Not set up yet — needs a one-time admin password   (disabled; rule missing only)
///   Install Sudoers Rule…                          (rule missing only)
///   ─────
///   On AC power | On battery (42%) — Keep Awake switches off at 10% | Power source unknown
///   ─────
///   Password after lid close: immediately | after 5 minutes | never | unknown   (disabled)
///   Lock Screen Settings…                          opens System Settings › Lock Screen
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
        if let notice = state.batteryGuardNotice {
            Text(notice)
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

        Text(BatteryGuard.menuLine(powerSource: state.powerSource, batteryPercent: state.batteryPercent))

        Divider()

        Text(state.screenLock.menuLine)
        Button("Lock Screen Settings…") {
            NSWorkspace.shared.open(Self.lockScreenSettingsURL)
        }

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

    private static let lockScreenSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!
}
