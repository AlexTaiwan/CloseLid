import XCTest
@testable import CloseLid

@MainActor
final class AppStateTests: XCTestCase {
    var shell: MockShellRunner!
    var privileged: MockPrivilegedRunner!
    var assertion: MockSleepAssertion!
    var defaults: UserDefaults!
    var loginItem: MockLoginItem!
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
        loginItem = MockLoginItem()
        alerts = []
        let controller = PowerController(shell: shell, privileged: privileged, assertion: assertion)
        sut = AppState(controller: controller, defaults: defaults, username: "alexwang", loginItem: loginItem)
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

    func testRefreshReadsLoginItemStatus() {
        loginItem.status = .enabled
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        XCTAssertEqual(sut.launchAtLogin, .enabled)
    }

    func testSetLaunchAtLoginOnRegistersAndReadsBack() {
        sut.setLaunchAtLogin(true)
        XCTAssertEqual(loginItem.calls, [true])
        XCTAssertEqual(sut.launchAtLogin, .enabled)
        XCTAssertNil(sut.lastError)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testSetLaunchAtLoginOffUnregisters() {
        loginItem.status = .enabled
        sut.setLaunchAtLogin(false)
        XCTAssertEqual(loginItem.calls, [false])
        XCTAssertEqual(sut.launchAtLogin, .disabled)
    }

    func testSetLaunchAtLoginNeedingApprovalIsNotAnError() {
        loginItem.needsApproval = true
        sut.setLaunchAtLogin(true)
        XCTAssertEqual(sut.launchAtLogin, .requiresApproval)
        XCTAssertNil(sut.lastError)
        XCTAssertTrue(alerts.isEmpty, "approval is a normal macOS step, not a failure")
    }

    func testSetLaunchAtLoginFailureAlertsAndKeepsRealStatus() {
        struct Boom: Error {}
        loginItem.error = Boom()
        sut.setLaunchAtLogin(true)
        XCTAssertEqual(sut.launchAtLogin, .disabled)
        XCTAssertNotNil(sut.lastError)
        XCTAssertEqual(alerts.map { $0.title }, ["CloseLid could not change the login item."])
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
        XCTAssertEqual(shell.calls.count, 4 + 1 + 2, "refresh(3 + screen lock 1) + sudo(1) + read-back probe pair(2)")
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

    // Spec §7: a probe-origin error row is cleared by the next successful background read.
    func testSuccessfulProbeClearsAnErrorLeftByAFailedProbe() {
        shell.enqueue(PowerCommand.probeSettings, status: 1, stderr: "boom")
        sut.refreshPowerOnly()
        XCTAssertNotNil(sut.lastError)
        enqueueProbe(settingsNormal)
        sut.refreshPowerOnly()
        XCTAssertEqual(sut.mode, .normal)
        XCTAssertNil(sut.lastError, "a transient tick failure must not stick")
    }

    // Spec §6: errors from user actions persist until the next successful action, so a
    // background tick must not wipe them.
    func testSuccessfulProbeKeepsAnErrorLeftByAFailedToggle() {
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 1, stderr: "sudo: a password is required\n")
        shell.enqueue(PowerCommand.probeHelper, status: 1)
        sut.toggle()
        let toggleError = sut.lastError
        XCTAssertNotNil(toggleError)

        enqueueProbe(settingsNormal)
        sut.refreshPowerOnly()
        XCTAssertEqual(sut.lastError, toggleError, "a 20 s tick must not clear a user-action error")
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

    // Trace for prepareForQuit(): fresh probe pair → decide → sudo → read-back probe pair.
    // The mock keys queues by argv, so the fresh read must be enqueued before the read-back.
    func testPrepareForQuitRevertsWhenAwakeAndNotOptedOut() {
        enqueueProbe(settingsAwake); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        enqueueProbe(settingsAwake)     // fresh read at the top of prepareForQuit
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal)    // read-back inside the controller
        sut.prepareForQuit()
        XCTAssertTrue(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
    }

    func testPrepareForQuitLeavesAwakeWhenOptedIn() {
        enqueueProbe(settingsAwake); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        sut.stayAwakeAfterQuit = true
        enqueueProbe(settingsAwake)     // fresh read still happens; the policy then declines
        sut.prepareForQuit()
        XCTAssertEqual(sut.mode, .awake, "the fresh read must have succeeded, not thrown")
        XCTAssertFalse(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
    }

    // The discriminating case for I2: the cached mode says normal (so a cache-based
    // decision would skip the revert), but the machine is really awake.
    func testPrepareForQuitUsesAFreshReadNotTheCachedMode() {
        enqueueProbe(settingsNormal); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        XCTAssertEqual(sut.mode, .normal)
        enqueueProbe(settingsAwake)     // the system actually went awake since that refresh
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal)
        sut.prepareForQuit()
        XCTAssertTrue(shell.calls.contains(PowerCommand.setSleepDisabled(false)),
                      "a stale .normal cache must not suppress the revert")
    }

    // Fail safe: if the fresh read fails, the revert still runs.
    func testPrepareForQuitRevertsWhenTheFreshReadFails() {
        shell.enqueue(PowerCommand.probeSettings, status: 1, stderr: "boom")   // fresh read fails
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal)                                           // read-back inside the controller
        sut.prepareForQuit()
        XCTAssertTrue(shell.calls.contains(PowerCommand.setSleepDisabled(false)),
                      "an unreadable state must not leave the Mac awake after quit")
    }

    func testPrepareForQuitWithUnreadableStateStillHonoursStayAwake() {
        sut.stayAwakeAfterQuit = true
        shell.enqueue(PowerCommand.probeSettings, status: 1, stderr: "boom")
        sut.prepareForQuit()
        XCTAssertFalse(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
    }

    func testPrepareForQuitDoesNotRevertWhenAlreadyNormal() {
        enqueueProbe(settingsNormal)
        sut.prepareForQuit()
        XCTAssertFalse(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
        XCTAssertEqual(shell.calls.count, 2, "fresh probe pair only")
    }

    // The revert can fail (rule removed behind the app's back). Quit must still finish.
    func testPrepareForQuitSurvivesAFailedRevert() {
        enqueueProbe(settingsAwake)
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 1, stderr: "sudo: a password is required\n")
        shell.enqueue(PowerCommand.probeHelper, status: 1)
        sut.prepareForQuit()
        XCTAssertEqual(shell.calls.last, PowerCommand.probeHelper)
        XCTAssertTrue(alerts.isEmpty)
    }

    // A second copy of the app must never touch the flag: the first copy owns it.
    // Without this, quitting either of two running copies silently reverts sleep
    // under the other one, and the Mac sleeps on the next lid close.
    func testSecondaryInstanceDoesNotRevertOnQuit() {
        enqueueProbe(settingsAwake); shell.enqueue(PowerCommand.probeHelper, status: 0)
        sut.refresh()
        let callsBeforeQuit = shell.calls.count
        sut.standDown()
        sut.prepareForQuit()
        XCTAssertFalse(shell.calls.contains(PowerCommand.setSleepDisabled(false)))
        XCTAssertEqual(shell.calls.count, callsBeforeQuit,
                       "a secondary instance must not even probe on the way out")
    }

    // MARK: battery guard

    private func batt(_ percent: Int, onAC: Bool = false) -> String {
        "Now drawing from '\(onAC ? "AC Power" : "Battery Power")'\n -InternalBattery-0 (id=1234)\t\(percent)%; discharging; 1:00 remaining present: true\n"
    }

    private func enqueueProbe(_ settings: String, batt: String) {
        shell.enqueue(PowerCommand.probeSettings, stdout: settings)
        shell.enqueue(PowerCommand.probeBattery, stdout: batt)
    }

    private func enqueueScreenLock() {
        shell.enqueue(PowerCommand.probeScreenLock, stderr: "screenLock delay is immediate")
    }

    private var revertCount: Int {
        shell.calls.filter { $0 == PowerCommand.setSleepDisabled(false) }.count
    }

    // Trace for periodicTick(): probe pair → guard (sudo + read-back probe pair, only if it fires) → screen lock.
    func testTickRevertsWhenAwakeOnLowBattery() {
        enqueueProbe(settingsAwake, batt: batt(10))
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal, batt: batt(10))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .normal)
        XCTAssertEqual(sut.batteryPercent, 10)
        XCTAssertEqual(sut.batteryGuardNotice, "Keep Awake switched itself off at 10% battery")
        XCTAssertNil(sut.lastError)
        XCTAssertTrue(alerts.isEmpty, "the guard is a background path and must not raise a modal")
        XCTAssertFalse(assertion.isHeld)
    }

    func testTickLeavesAwakeAloneAboveThreshold() {
        enqueueProbe(settingsAwake, batt: batt(11))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .awake)
        XCTAssertEqual(revertCount, 0)
        XCTAssertNil(sut.batteryGuardNotice)
        XCTAssertEqual(shell.calls.count, 3, "probe pair + screen lock, nothing else")
    }

    func testTickLeavesAwakeAloneOnACEvenWhenLow() {
        enqueueProbe(settingsAwake, batt: batt(5, onAC: true))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .awake)
        XCTAssertEqual(revertCount, 0)
    }

    func testTickDoesNothingWhenNormalOnLowBattery() {
        enqueueProbe(settingsNormal, batt: batt(5))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(revertCount, 0)
        XCTAssertNil(sut.batteryGuardNotice)
    }

    func testTickDoesNothingWhenChargeIsUnknown() {
        enqueueProbe(settingsAwake, batt: "Now drawing from 'Battery Power'\n")
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertNil(sut.batteryPercent)
        XCTAssertEqual(sut.mode, .awake)
        XCTAssertEqual(revertCount, 0)
    }

    // A failed revert must be visible, must not alert, and must not retry every tick.
    func testGuardFailureShowsErrorAndRetriesOnlyAfterAFurtherDrop() {
        enqueueProbe(settingsAwake, batt: batt(10))
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 1, stderr: "sudo: a password is required\n")
        shell.enqueue(PowerCommand.probeHelper, status: 1)
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .awake)
        XCTAssertEqual(sut.lastError,
                       "Battery is at 10% but Keep Awake could not be switched off. Sudoers rule not installed. Use “Install Sudoers Rule…” first.")
        XCTAssertNil(sut.batteryGuardNotice)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(revertCount, 1)

        // Same charge: no second attempt, and the error row survives the successful probe.
        enqueueProbe(settingsAwake, batt: batt(10))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(revertCount, 1)
        XCTAssertNotNil(sut.lastError)

        // Charge dropped: try again.
        enqueueProbe(settingsAwake, batt: batt(9))
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal, batt: batt(9))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(revertCount, 2)
        XCTAssertEqual(sut.mode, .normal)
        XCTAssertEqual(sut.batteryGuardNotice, "Keep Awake switched itself off at 9% battery")
    }

    // Switching Keep Awake back on below the threshold is the user's call: the guard
    // stays off until the battery has recovered, then arms again.
    func testManualEnableBelowThresholdOverridesGuardUntilRecovered() {
        enqueueProbe(settingsAwake, batt: batt(10))
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal, batt: batt(10))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .normal)

        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 0)
        enqueueProbe(settingsAwake, batt: batt(9))
        sut.toggle()
        XCTAssertEqual(sut.mode, .awake)
        XCTAssertNil(sut.batteryGuardNotice, "a successful toggle clears the notice")

        enqueueProbe(settingsAwake, batt: batt(8))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .awake, "the guard must respect the manual override")
        XCTAssertEqual(revertCount, 1)

        // Plugged in: recovered, so the override ends.
        enqueueProbe(settingsAwake, batt: batt(9, onAC: true))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .awake)

        // Unplugged again while still low: the guard fires again.
        enqueueProbe(settingsAwake, batt: batt(9))
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settingsNormal, batt: batt(9))
        enqueueScreenLock()
        sut.periodicTick()
        XCTAssertEqual(sut.mode, .normal)
        XCTAssertEqual(revertCount, 2)
    }

    func testSecondaryInstanceNeverRunsTheGuard() {
        enqueueProbe(settingsAwake, batt: batt(5))
        sut.refreshPowerOnly()
        sut.standDown()
        sut.enforceBatteryGuard()
        XCTAssertEqual(revertCount, 0)
        XCTAssertEqual(sut.mode, .awake)
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
