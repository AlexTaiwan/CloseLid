import Foundation
import Observation
import os

@MainActor
@Observable
final class AppState {
    /// Extends the §7 logging rules to the happy path, after a 2026-09-03 report of
    /// "it was on and it still slept" had to be answered by reconstructing the flag's
    /// history from CloseLid's power assertion in `pmset -g log`. Every mode transition
    /// and every toggle attempt now leaves a line, so the next such report is answered
    /// by `log show --predicate 'subsystem == "com.alexwang.CloseLid"'`.
    private static let log = Logger(subsystem: "com.alexwang.CloseLid", category: "state")

    // MARK: Live wiring
    static let shared: AppState = {
        let shell = ProcessShellRunner()
        let controller = PowerController(
            shell: shell,
            privileged: OsascriptPrivilegedRunner(shell: shell),
            assertion: IOPMSleepAssertion()
        )
        return AppState(controller: controller, defaults: .standard, username: NSUserName(), loginItem: SMAppServiceLoginItem())
    }()

    // MARK: Observable state
    private(set) var mode: PowerMode = .unknown
    private(set) var powerSource: PowerSource = .unknown
    /// Internal battery charge, 0...100; `nil` when unknown or there is no battery.
    private(set) var batteryPercent: Int?
    /// Set when the battery guard switched Keep Awake off, so the reason is still on
    /// the menu when the lid is opened again. Cleared by the next successful toggle.
    private(set) var batteryGuardNotice: String?
    private(set) var helperInstalled = false
    private(set) var launchAtLogin: LoginItemStatus = .disabled
    private(set) var screenLock: ScreenLockDelay = .unknown
    var lastError: String?

    /// Shows a native alert for failures of user-initiated actions. Injected so tests
    /// record instead of blocking on a modal; the live wiring is in AppDelegate.
    /// Never called from the periodic refresh.
    @ObservationIgnored var alertPresenter: (_ title: String, _ message: String) -> Void = { _, _ in }

    /// Stored (not computed) so Observation tracks it and the menu Toggle re-renders.
    var stayAwakeAfterQuit: Bool {
        didSet { defaults.set(stayAwakeAfterQuit, forKey: Self.stayAwakeKey) }
    }

    private static let stayAwakeKey = "stayAwakeAfterQuit"
    private let controller: PowerController
    private let defaults: UserDefaults
    private let username: String
    private let loginItem: LoginItemManaging
    private var refreshTimer: Timer?
    /// Set when another copy of the app is already running. That copy owns the flag,
    /// so this one must leave it alone — above all on the way out.
    private var isSecondaryInstance = false
    /// True while `lastError` holds a message written by a failed `refreshPowerOnly`.
    /// Spec §6/§7: a later successful background read clears a probe-origin error row,
    /// but errors from user actions persist until the next successful action.
    private var lastErrorIsFromProbe = false
    /// True after the user switched Keep Awake on by hand while the battery was already
    /// low. The guard then stays out of the way until the battery has recovered.
    private var batteryGuardOverridden = false
    /// Charge at which the guard last failed to restore normal sleep. It retries only
    /// once the charge has dropped further, so a missing sudoers rule does not produce
    /// a failing `sudo -n` every tick.
    private var batteryGuardFailedAtPercent: Int?

    init(controller: PowerController, defaults: UserDefaults, username: String, loginItem: LoginItemManaging) {
        self.controller = controller
        self.defaults = defaults
        self.username = username
        self.loginItem = loginItem
        self.stayAwakeAfterQuit = defaults.bool(forKey: Self.stayAwakeKey)
    }

    /// Call once from the app delegate. Keeps the menu roughly current even though
    /// `.menu`-style MenuBarExtra content does not get reliable onAppear callbacks.
    /// The periodic tick only re-reads pmset; it does NOT re-probe sudo, because a
    /// failing `sudo -n -l` writes an auth-failure line to the system log each time.
    func startPeriodicRefresh(interval: TimeInterval = 20) {
        refresh()
        enforceBatteryGuard()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.periodicTick()
            }
        }
    }

    /// One background tick. Separate from the Timer closure so tests can drive it.
    func periodicTick() {
        refreshPowerOnly()
        enforceBatteryGuard()
        // Re-read every tick: the user changes it in System Settings, not here.
        refreshScreenLock()
    }

    /// Restores normal sleep when Keep Awake is on and the battery is low. Works only
    /// from the state the last probe published; it runs no command unless it reverts.
    /// Background path: it never raises an alert.
    func enforceBatteryGuard() {
        guard !isSecondaryInstance else { return }
        if BatteryGuard.isRecovered(powerSource: powerSource, batteryPercent: batteryPercent) {
            batteryGuardOverridden = false
            batteryGuardFailedAtPercent = nil
        }
        guard BatteryGuard.shouldRevert(mode: mode, powerSource: powerSource, batteryPercent: batteryPercent),
              let percent = batteryPercent,
              !batteryGuardOverridden else { return }
        if let failedAt = batteryGuardFailedAtPercent, percent >= failedAt { return }

        Self.log.error("battery guard: \(percent, privacy: .public)% on battery, switching Keep Awake off")
        do {
            apply(try controller.setSleepDisabled(false))
            batteryGuardFailedAtPercent = nil
            batteryGuardNotice = BatteryGuard.notice(percent: percent)
        } catch {
            let reason = Self.message(for: error)
            Self.log.error("battery guard: could not switch Keep Awake off: \(reason, privacy: .public)")
            batteryGuardFailedAtPercent = percent
            lastError = "Battery is at \(percent)% but Keep Awake could not be switched off. \(reason)"
            lastErrorIsFromProbe = false
        }
    }

    // MARK: Actions

    /// Full refresh: pmset state + helper presence. Used on launch and after actions.
    func refresh() {
        refreshPowerOnly()
        helperInstalled = controller.isHelperInstalled()
        launchAtLogin = loginItem.status
        refreshScreenLock()
    }

    /// Re-reads `sysadminctl -screenLock status`. Never touches `lastError`.
    func refreshScreenLock() {
        screenLock = controller.probeScreenLock()
    }

    /// Re-reads `pmset -g` / `pmset -g batt` only.
    func refreshPowerOnly() {
        do {
            apply(try controller.probe())
            // Only a message this method wrote may be cleared here; a toggle or install
            // failure must stay on the menu until the next successful user action.
            if lastErrorIsFromProbe { clearError() }
        } catch {
            if mode != .unknown {
                Self.log.error("mode changed: \(Self.name(self.mode), privacy: .public) -> unknown (probe failed)")
            }
            mode = .unknown
            lastError = "Could not read power settings: \(error.localizedDescription)"
            lastErrorIsFromProbe = true
        }
    }

    func toggle() {
        let target: Bool
        switch mode {
        case .normal: target = true
        case .awake: target = false
        case .unknown:
            // Silent to the user by design (the row is disabled), but never silent in
            // the log: this is the path where a click does nothing at all.
            Self.log.error("toggle ignored: mode is unknown")
            return
        }
        Self.log.notice("toggle requested: \(self.mode == .awake ? "awake" : "normal", privacy: .public) -> \(target ? "awake" : "normal", privacy: .public)")
        do {
            // setSleepDisabled already re-probed and verified; use that snapshot directly.
            apply(try controller.setSleepDisabled(target))
            clearError()
            batteryGuardNotice = nil
            // Switching it on by hand below the threshold is a deliberate choice;
            // without this the guard would undo it on the next tick.
            batteryGuardOverridden = target
                && BatteryGuard.isLow(powerSource: powerSource, batteryPercent: batteryPercent)
            if batteryGuardOverridden {
                Self.log.notice("battery guard overridden by the user until the battery recovers")
            }
        } catch PowerError.helperNotInstalled {
            // The controller already ran `sudo -n -l` and found no rule.
            helperInstalled = false
            fail(Self.toggleAlertTitle, with: PowerError.helperNotInstalled)
        } catch {
            fail(Self.toggleAlertTitle, with: error)
            refreshPowerOnly()
        }
    }

    private func apply(_ snapshot: PmsetSnapshot) {
        if snapshot.mode != mode {
            Self.log.notice("mode changed: \(Self.name(self.mode), privacy: .public) -> \(Self.name(snapshot.mode), privacy: .public)")
        }
        mode = snapshot.mode
        powerSource = snapshot.powerSource
        batteryPercent = snapshot.batteryPercent
    }

    private static func name(_ mode: PowerMode) -> String {
        switch mode {
        case .normal: return "normal"
        case .awake: return "awake"
        case .unknown: return "unknown"
        }
    }

    func installHelper() {
        do {
            try controller.installHelper(username: username)
            clearError()
        } catch PowerError.cancelled {
            // user dismissed the password dialog; nothing to report
        } catch {
            fail(Self.ruleAlertTitle, with: error)
        }
        refresh()
    }

    func removeHelper() {
        do {
            try controller.removeHelper(currentlyAwake: mode == .awake)
            clearError()
        } catch PowerError.cancelled {
            // silent
        } catch {
            fail(Self.ruleAlertTitle, with: error)
        }
        refresh()
    }

    /// User action. Approval-required is a normal outcome, not a failure.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            try loginItem.setEnabled(on)
            clearError()
        } catch {
            fail(Self.loginItemAlertTitle, with: error)
        }
        launchAtLogin = loginItem.status
    }

    private static let toggleAlertTitle = "CloseLid could not change the sleep setting."
    private static let ruleAlertTitle = "CloseLid could not update the sudoers rule."
    private static let loginItemAlertTitle = "CloseLid could not change the login item."

    /// Records the error for the menu and raises the alert. User-initiated paths only.
    private func fail(_ title: String, with error: Error) {
        let message = Self.message(for: error)
        lastError = message
        lastErrorIsFromProbe = false
        alertPresenter(title, message)
    }

    private func clearError() {
        lastError = nil
        lastErrorIsFromProbe = false
    }

    /// Marks this process as the losing side of the instance guard: it stops polling
    /// and will not write the flag, so quitting it cannot disturb the copy that owns it.
    func standDown() {
        isSecondaryInstance = true
        refreshTimer?.invalidate()
        Self.log.notice("standing down: another copy of CloseLid is already running")
    }

    /// Synchronous on purpose: called from applicationWillTerminate / SIGTERM.
    func prepareForQuit() {
        refreshTimer?.invalidate()
        guard !isSecondaryInstance else { return }
        // Decide from a fresh read, never from `mode`: it can be up to one tick stale.
        // If the fresh read itself fails, QuitPolicy still reverts (fail safe).
        refreshPowerOnly()
        let sleepDisabled: Bool? = (mode == .awake) ? true : (mode == .normal ? false : nil)
        guard QuitPolicy.shouldRevertOnQuit(sleepDisabled: sleepDisabled, stayAwakeAfterQuit: stayAwakeAfterQuit) else {
            Self.log.notice("quit: leaving the sleep setting as it is (\(Self.name(self.mode), privacy: .public))")
            return
        }
        do {
            try controller.setSleepDisabled(false)
            Self.log.notice("quit: normal sleep restored")
        } catch {
            // Nobody is left to show an alert to; the log is the only trace that the
            // Mac was left awake.
            Self.log.error("quit: could not restore normal sleep: \(Self.message(for: error), privacy: .public)")
        }
    }

    // MARK: Messages

    private static func message(for error: Error) -> String {
        switch error {
        case PowerError.helperNotInstalled:
            return "Sudoers rule not installed. Use “Install Sudoers Rule…” first."
        case let PowerError.commandFailed(stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Command failed with no error output." : "Command failed: \(detail)"
        case let PowerError.readBackMismatch(expected, actual):
            return "System did not apply the change (wanted \(expected ? "awake" : "normal"), read back \(actual.map { $0 ? "awake" : "normal" } ?? "unknown"))."
        case PowerError.cancelled:
            return "Cancelled."
        default:
            return error.localizedDescription
        }
    }
}
