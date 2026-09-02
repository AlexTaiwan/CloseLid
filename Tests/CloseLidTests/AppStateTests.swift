import XCTest
@testable import CloseLid

@MainActor
final class AppStateTests: XCTestCase {
    var shell: MockShellRunner!
    var privileged: MockPrivilegedRunner!
    var assertion: MockSleepAssertion!
    var defaults: UserDefaults!
    var sut: AppState!
    var alerts: [(title: String, message: String)] = []

    let settingsNormal = "System-wide power settings:\nCurrently in use:\n sleep 0\n"
    let settingsAwake = "System-wide power settings:\nCurrently in use:\n SleepDisabled 1\n"
    let battAC = "Now drawing from 'AC Power'\n"

    override func setUp() {
        shell = MockShellRunner()
        privileged = MockPrivilegedRunner()
        assertion = MockSleepAssertion()
        defaults = UserDefaults(suiteName: "CloseLidTests.\(UUID().uuidString)")!
        alerts = []
        let controller = PowerController(shell: shell, privileged: privileged, assertion: assertion)
        sut = AppState(controller: controller, defaults: defaults, username: "alexwang")
        sut.alertPresenter = { [unowned self] title, message in self.alerts.append((title, message)) }
    }

    private func enqueueProbe(_ settings: String) {
        shell.enqueue(PowerCommand.probeSettings, stdout: settings)
        shell.enqueue(PowerCommand.probeBattery, stdout: battAC)
    }

    func testRefreshReadsModePowerAndHelper() {
        enqueueProbe(settingsAwake)
        shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        XCTAssertEqual(sut.mode, .awake)
        XCTAssertEqual(sut.powerSource, .ac)
        XCTAssertTrue(sut.helperInstalled)
        XCTAssertNil(sut.lastError)
    }

    // Trace for toggle(): setSleepDisabled(x) → probe pair (inside the controller) → apply.
    // Nothing else runs on success, so exactly one probe pair is enqueued after the sudo call.
    func testToggleFromNormalEnables() {
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 0)
        enqueueProbe(settingsAwake)
        sut.toggle()
        XCTAssertEqual(sut.mode, .awake)
        XCTAssertNil(sut.lastError)
        XCTAssertEqual(shell.calls.count, 3 + 1 + 2, "refresh(3) + sudo(1) + read-back probe pair(2)")
    }

    func testToggleFromAwakeDisables() {
        enqueueProbe(settingsAwake); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal)
        sut.toggle()
        XCTAssertEqual(sut.mode, .normal)
        XCTAssertNil(sut.lastError)
    }

    // Trace: sudo fails → controller runs probeHelper (status 1) → helperNotInstalled.
    // AppState must not re-probe; it sets helperInstalled = false from the error.
    func testToggleWithoutHelperSetsErrorAndFlagsHelperMissing() {
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 1, stderr: "sudo: a password is required\n")
        shell.enqueue(PowerCommand.probeHelper, status: 1)
        sut.toggle()
        XCTAssertEqual(sut.mode, .normal)
        XCTAssertFalse(sut.helperInstalled)
        XCTAssertEqual(sut.lastError, "Sudoers rule not installed. Use “Install Sudoers Rule…” first.")
        XCTAssertEqual(alerts.map { $0.title }, ["CloseLid could not change the sleep setting."])
        XCTAssertEqual(alerts.map { $0.message }, [sut.lastError])
    }

    func testTimerRefreshNeverAlerts() {
        shell.enqueue(PowerCommand.probeSettings, status: 1, stderr: "boom")
        // no probeBattery enqueued: the mock throws UnexpectedCommand → refreshPowerOnly catches it
        sut.refreshPowerOnly()
        XCTAssertEqual(sut.mode, .unknown)
        XCTAssertNotNil(sut.lastError)
        XCTAssertTrue(alerts.isEmpty, "background refresh must stay silent")
    }

    // Trace: sudo ok → read-back probe says still normal → readBackMismatch → refreshPowerOnly (one more probe pair).
    func testToggleReadBackMismatchShowsErrorAndRefreshes() {
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 0)
        enqueueProbe(settingsNormal)   // read-back inside controller
        enqueueProbe(settingsNormal)   // refreshPowerOnly after the error
        sut.toggle()
        XCTAssertEqual(sut.mode, .normal)
        XCTAssertEqual(sut.lastError, "System did not apply the change (wanted awake, read back normal).")
        XCTAssertEqual(alerts.count, 1)
    }

    func testToggleWhenUnknownDoesNothing() {
        enqueueProbe("garbage"); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        XCTAssertEqual(sut.mode, .unknown)
        sut.toggle()
        XCTAssertFalse(shell.calls.contains(PowerCommand.setSleepDisabled(true)))
        XCTAssertFalse(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
    }

    func testStayAwakePreferencePersistsInDefaults() {
        XCTAssertFalse(sut.stayAwakeAfterQuit)
        sut.stayAwakeAfterQuit = true
        XCTAssertTrue(defaults.bool(forKey: "stayAwakeAfterQuit"))
    }

    func testPrepareForQuitRevertsWhenAwakeAndNotOptedOut() {
        enqueueProbe(settingsAwake); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal)
        sut.prepareForQuit()
        XCTAssertTrue(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
    }

    func testPrepareForQuitLeavesAwakeWhenOptedIn() {
        enqueueProbe(settingsAwake); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        sut.stayAwakeAfterQuit = true
        sut.prepareForQuit()
        XCTAssertFalse(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
    }

    func testInstallHelperRefreshesAndClearsError() {
        sut.lastError = "old"
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.installHelper()
        XCTAssertEqual(privileged.scripts.count, 1)
        XCTAssertEqual(privileged.prompts, [PrivilegedPrompt.install])
        XCTAssertTrue(sut.helperInstalled)
        XCTAssertNil(sut.lastError)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testInstallHelperCancelIsSilent() {
        privileged.error = .cancelled
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 1)
        sut.installHelper()
        XCTAssertNil(sut.lastError)
        XCTAssertFalse(sut.helperInstalled)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testEmptyStderrGetsAReadableMessage() {
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 1, stderr: "")
        shell.enqueue(PowerCommand.probeHelper, status: 0)   // rule present → commandFailed("")
        enqueueProbe(settingsNormal)                          // refreshPowerOnly after the error
        sut.toggle()
        XCTAssertEqual(sut.lastError, "Command failed with no error output.")
    }

    func testInstallHelperFailureAlerts() {
        privileged.error = .failed("visudo: parse error\n")
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 1)
        sut.installHelper()
        XCTAssertEqual(sut.lastError, "Command failed: visudo: parse error")
        XCTAssertEqual(alerts.map { $0.title }, ["CloseLid could not update the sudoers rule."])
    }

    func testRemoveHelperRefreshesAndTellsPromptAboutRevertWhenAwake() {
        enqueueProbe(settingsAwake); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 1)
        sut.removeHelper()
        XCTAssertEqual(privileged.scripts, [PowerCommand.removeHelperScript])
        XCTAssertEqual(privileged.prompts, [PrivilegedPrompt.removeWhileAwake])
        XCTAssertFalse(sut.helperInstalled)
        XCTAssertEqual(sut.mode, .normal)
    }

    func testRemoveHelperWhileNormalUsesPlainPrompt() {
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 1)
        sut.removeHelper()
        XCTAssertEqual(privileged.prompts, [PrivilegedPrompt.remove])
    }
}
