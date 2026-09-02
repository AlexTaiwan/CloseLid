import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    // MARK: Live wiring
    static let shared: AppState = {
        let shell = ProcessShellRunner()
        let controller = PowerController(
            shell: shell,
            privileged: OsascriptPrivilegedRunner(shell: shell),
            assertion: IOPMSleepAssertion()
        )
        return AppState(controller: controller, defaults: .standard, username: NSUserName())
    }()

    // MARK: Observable state
    private(set) var mode: PowerMode = .unknown
    private(set) var powerSource: PowerSource = .unknown
    private(set) var helperInstalled = false
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
    private var refreshTimer: Timer?

    init(controller: PowerController, defaults: UserDefaults, username: String) {
        self.controller = controller
        self.defaults = defaults
        self.username = username
        self.stayAwakeAfterQuit = defaults.bool(forKey: Self.stayAwakeKey)
    }

    /// Call once from the app delegate. Keeps the menu roughly current even though
    /// `.menu`-style MenuBarExtra content does not get reliable onAppear callbacks.
    /// The periodic tick only re-reads pmset; it does NOT re-probe sudo, because a
    /// failing `sudo -n -l` writes an auth-failure line to the system log each time.
    func startPeriodicRefresh(interval: TimeInterval = 20) {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPowerOnly() }
        }
    }

    // MARK: Actions

    /// Full refresh: pmset state + helper presence. Used on launch and after actions.
    func refresh() {
        refreshPowerOnly()
        helperInstalled = controller.isHelperInstalled()
    }

    /// Re-reads `pmset -g` / `pmset -g batt` only.
    func refreshPowerOnly() {
        do {
            apply(try controller.probe())
        } catch {
            mode = .unknown
            lastError = "Could not read power settings: \(error.localizedDescription)"
        }
    }

    func toggle() {
        let target: Bool
        switch mode {
        case .normal: target = true
        case .awake: target = false
        case .unknown: return
        }
        do {
            // setSleepDisabled already re-probed and verified; use that snapshot directly.
            apply(try controller.setSleepDisabled(target))
            lastError = nil
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
        mode = snapshot.mode
        powerSource = snapshot.powerSource
    }

    func installHelper() {
        do {
            try controller.installHelper(username: username)
            lastError = nil
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
            lastError = nil
        } catch PowerError.cancelled {
            // silent
        } catch {
            fail(Self.ruleAlertTitle, with: error)
        }
        refresh()
    }

    private static let toggleAlertTitle = "CloseLid could not change the sleep setting."
    private static let ruleAlertTitle = "CloseLid could not update the sudoers rule."

    /// Records the error for the menu and raises the alert. User-initiated paths only.
    private func fail(_ title: String, with error: Error) {
        let message = Self.message(for: error)
        lastError = message
        alertPresenter(title, message)
    }

    /// Synchronous on purpose: called from applicationWillTerminate / SIGTERM.
    func prepareForQuit() {
        refreshTimer?.invalidate()
        let sleepDisabled: Bool? = (mode == .awake) ? true : (mode == .normal ? false : nil)
        guard QuitPolicy.shouldRevertOnQuit(sleepDisabled: sleepDisabled, stayAwakeAfterQuit: stayAwakeAfterQuit) else { return }
        _ = try? controller.setSleepDisabled(false)
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
