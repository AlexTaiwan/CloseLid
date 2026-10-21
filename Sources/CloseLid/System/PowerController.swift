import Foundation
import os

enum PowerError: Error, Equatable {
    case helperNotInstalled
    case commandFailed(String)
    case readBackMismatch(expected: Bool, actual: Bool?)
    case cancelled
}

/// Orchestrates every interaction with the system. Rule: after any write, re-read
/// `pmset -g` and report *that*; never assume the write succeeded.
final class PowerController {
    /// Spec §7: the two states a user would file a bug about must leave a trace.
    /// Read with `log show --predicate 'subsystem == "com.alexwang.CloseLid"'`.
    private static let log = Logger(subsystem: "com.alexwang.CloseLid", category: "power")

    private let shell: ShellRunning
    private let privileged: PrivilegedRunning
    private let assertion: SleepAssertionHolding

    init(shell: ShellRunning, privileged: PrivilegedRunning, assertion: SleepAssertionHolding) {
        self.shell = shell
        self.privileged = privileged
        self.assertion = assertion
    }

    /// Reads the live system state and aligns the idle-sleep assertion with it.
    func probe() throws -> PmsetSnapshot {
        let settings = try shell.run(PowerCommand.probeSettings)
        guard settings.status == 0 else {
            throw PowerError.commandFailed(settings.stderr)
        }
        // Battery reporting is ancillary: its failure must not hide the sleep flag
        // or prevent the quit path from restoring normal sleep.
        let battery = try? shell.run(PowerCommand.probeBattery)
        let sleepDisabled = PmsetParser.sleepDisabled(fromSettings: settings.stdout)
        if sleepDisabled == nil {
            // Public on purpose: pmset -g output holds no personal data and the raw
            // text is the only way to diagnose a parser miss from a user's log.
            Self.log.error("pmset -g output not parseable; raw text: \(settings.stdout, privacy: .public)")
        }
        let snapshot = PmsetSnapshot(
            sleepDisabled: sleepDisabled,
            powerSource: battery?.status == 0
                ? PmsetParser.powerSource(fromBattery: battery!.stdout) : .unknown
        )
        syncAssertion(to: snapshot.sleepDisabled)
        return snapshot
    }

    /// Informational only, so a failure reads as `.unknown` instead of throwing.
    func probeScreenLock() -> ScreenLockDelay {
        guard let result = try? shell.run(PowerCommand.probeScreenLock), result.status == 0 else {
            return .unknown
        }
        return ScreenLockParser.delay(fromStatus: result.stderr + "\n" + result.stdout)
    }

    func isHelperInstalled() -> Bool {
        (try? shell.run(PowerCommand.probeHelper))?.status == 0
    }

    /// Flips the flag through non-interactive sudo, then verifies by re-probing.
    @discardableResult
    func setSleepDisabled(_ enabled: Bool) throws -> PmsetSnapshot {
        let result = try shell.run(PowerCommand.setSleepDisabled(enabled))
        guard result.status == 0 else {
            if !isHelperInstalled() { throw PowerError.helperNotInstalled }
            throw PowerError.commandFailed(result.stderr)
        }
        let snapshot = try probe()
        guard snapshot.sleepDisabled == enabled else {
            let actual = snapshot.sleepDisabled.map(String.init(describing:)) ?? "unknown"
            Self.log.error("read-back mismatch: wrote disablesleep \(enabled ? "1" : "0", privacy: .public), read back \(actual, privacy: .public)")
            throw PowerError.readBackMismatch(expected: enabled, actual: snapshot.sleepDisabled)
        }
        return snapshot
    }

    func installHelper(username: String) throws {
        let rule = try SudoersRule.render(username: username)
        try runPrivileged(PowerCommand.installHelperScript(ruleText: rule), prompt: PrivilegedPrompt.install)
    }

    /// Reverts sleep to normal (inside the root script) and deletes the sudoers rule.
    /// `currentlyAwake` only selects the prompt so the user is told about the revert.
    func removeHelper(currentlyAwake: Bool) throws {
        let prompt = currentlyAwake ? PrivilegedPrompt.removeWhileAwake : PrivilegedPrompt.remove
        try runPrivileged(PowerCommand.removeHelperScript, prompt: prompt)
        assertion.release()
    }

    // MARK: - Private

    private func runPrivileged(_ script: String, prompt: String) throws {
        do {
            try privileged.runAsRoot(script: script, prompt: prompt)
        } catch PrivilegedError.cancelled {
            throw PowerError.cancelled
        } catch let PrivilegedError.failed(message) {
            throw PowerError.commandFailed(message)
        }
    }

    private func syncAssertion(to sleepDisabled: Bool?) {
        if sleepDisabled == true { assertion.acquire() } else { assertion.release() }
    }
}
