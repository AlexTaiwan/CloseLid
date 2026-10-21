import XCTest
@testable import CloseLid

final class PowerControllerTests: XCTestCase {
    var shell: MockShellRunner!
    var privileged: MockPrivilegedRunner!
    var assertion: MockSleepAssertion!
    var sut: PowerController!

    let settingsNormal = "System-wide power settings:\nCurrently in use:\n sleep 0\n"
    let settingsAwake = "System-wide power settings:\nCurrently in use:\n SleepDisabled 1\n sleep 0\n"
    let battAC = "Now drawing from 'AC Power'\n"
    let battBattery = "Now drawing from 'Battery Power'\n"

    override func setUp() {
        shell = MockShellRunner()
        privileged = MockPrivilegedRunner()
        assertion = MockSleepAssertion()
        sut = PowerController(shell: shell, privileged: privileged, assertion: assertion)
    }

    private func enqueueProbe(settings: String, batt: String) {
        shell.enqueue(PowerCommand.probeSettings, stdout: settings)
        shell.enqueue(PowerCommand.probeBattery, stdout: batt)
    }

    // MARK: probe

    func testProbeParsesBothCommands() throws {
        enqueueProbe(settings: settingsAwake, batt: battBattery)
        let snap = try sut.probe()
        XCTAssertEqual(snap, PmsetSnapshot(sleepDisabled: true, powerSource: .battery))
    }

    func testProbeSyncsAssertionToSystemState() throws {
        enqueueProbe(settings: settingsAwake, batt: battAC)
        _ = try sut.probe()
        XCTAssertTrue(assertion.isHeld, "leftover Awake state from a crash must re-acquire the idle assertion")

        enqueueProbe(settings: settingsNormal, batt: battAC)
        _ = try sut.probe()
        XCTAssertFalse(assertion.isHeld)
    }

    func testProbeWithUnparseableOutputReportsUnknownAndReleasesAssertion() throws {
        assertion.acquire()
        enqueueProbe(settings: "garbage", batt: "")
        let snap = try sut.probe()
        XCTAssertNil(snap.sleepDisabled)
        XCTAssertEqual(snap.mode, .unknown)
        XCTAssertFalse(assertion.isHeld)
    }

    func testFailedSettingsCommandRejectsEvenParseableOutput() {
        shell.enqueue(PowerCommand.probeSettings, status: 1, stdout: settingsAwake, stderr: "failed")
        XCTAssertThrowsError(try sut.probe())
    }

    func testBatteryFailureDoesNotHideAwakeState() throws {
        shell.enqueue(PowerCommand.probeSettings, stdout: settingsAwake)
        shell.enqueue(PowerCommand.probeBattery, status: 1, stderr: "failed")
        let snapshot = try sut.probe()
        XCTAssertEqual(snapshot.mode, .awake)
        XCTAssertEqual(snapshot.powerSource, .unknown)
        XCTAssertTrue(assertion.isHeld)
    }

    func testBatteryLaunchFailureDoesNotPreventDisableVerification() throws {
        shell.enqueue(PowerCommand.setSleepDisabled(false))
        shell.enqueue(PowerCommand.probeSettings, stdout: settingsNormal)
        // No battery response: the mock throws a launch-style error.
        XCTAssertEqual(try sut.setSleepDisabled(false).mode, .normal)
    }

    // MARK: helper detection

    func testHelperInstalledWhenSudoListSucceeds() {
        shell.enqueue(PowerCommand.probeHelper, status: 0)
        XCTAssertTrue(sut.isHelperInstalled())
    }

    func testHelperNotInstalledWhenSudoListFails() {
        shell.enqueue(PowerCommand.probeHelper, status: 1, stderr: "sudo: a password is required\n")
        XCTAssertFalse(sut.isHelperInstalled())
    }

    // MARK: set

    func testEnableRunsSudoThenReadsBackAndHoldsAssertion() throws {
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 0)
        enqueueProbe(settings: settingsAwake, batt: battAC)
        let snap = try sut.setSleepDisabled(true)
        XCTAssertEqual(snap.mode, .awake)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertEqual(shell.calls.first, PowerCommand.setSleepDisabled(true))
    }

    func testDisableRunsSudoThenReadsBackAndReleasesAssertion() throws {
        assertion.acquire()
        shell.enqueue(PowerCommand.setSleepDisabled(false), status: 0)
        enqueueProbe(settings: settingsNormal, batt: battAC)
        let snap = try sut.setSleepDisabled(false)
        XCTAssertEqual(snap.mode, .normal)
        XCTAssertFalse(assertion.isHeld)
    }

    func testEnableWithoutHelperThrowsHelperNotInstalled() {
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 1, stderr: "sudo: a password is required\n")
        shell.enqueue(PowerCommand.probeHelper, status: 1)
        XCTAssertThrowsError(try sut.setSleepDisabled(true)) { error in
            XCTAssertEqual(error as? PowerError, .helperNotInstalled)
        }
        XCTAssertFalse(assertion.isHeld)
    }

    func testEnableFailureWithHelperPresentThrowsCommandFailed() {
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 1, stderr: "pmset: something broke\n")
        shell.enqueue(PowerCommand.probeHelper, status: 0)
        XCTAssertThrowsError(try sut.setSleepDisabled(true)) { error in
            XCTAssertEqual(error as? PowerError, .commandFailed("pmset: something broke\n"))
        }
    }

    func testEnableWhoseReadBackDisagreesThrowsMismatchAndDoesNotHoldAssertion() {
        shell.enqueue(PowerCommand.setSleepDisabled(true), status: 0)
        enqueueProbe(settings: settingsNormal, batt: battAC) // system still says normal
        XCTAssertThrowsError(try sut.setSleepDisabled(true)) { error in
            XCTAssertEqual(error as? PowerError, .readBackMismatch(expected: true, actual: false))
        }
        XCTAssertFalse(assertion.isHeld)
    }

    // MARK: install / remove

    func testInstallHelperRendersRuleForUserAndRunsAsRootWithInstallPrompt() throws {
        try sut.installHelper(username: "alexwang")
        XCTAssertEqual(privileged.scripts.count, 1)
        XCTAssertTrue(privileged.scripts[0].contains("alexwang ALL=(root) NOPASSWD:"))
        XCTAssertTrue(privileged.scripts[0].contains("/usr/sbin/visudo -c -f"))
        XCTAssertEqual(privileged.prompts, [PrivilegedPrompt.install])
    }

    /// The only root script the install path may ever hand to `PrivilegedRunning`
    /// is `PowerCommand.installHelperScript` built from the rendered rule.
    func testInstallHelperPassesExactInstallScript() throws {
        try sut.installHelper(username: "alexwang")
        let rule = try SudoersRule.render(username: "alexwang")
        XCTAssertEqual(privileged.scripts, [PowerCommand.installHelperScript(ruleText: rule)])
    }

    func testPromptsNameCloseLidAndSayWhatChanges() {
        XCTAssertEqual(PrivilegedPrompt.install,
            "CloseLid needs your password once to add a sudoers rule that lets it turn lid-close sleep on and off without asking again.")
        XCTAssertEqual(PrivilegedPrompt.remove,
            "CloseLid needs your password once to remove the sudoers rule it installed.")
        XCTAssertEqual(PrivilegedPrompt.removeWhileAwake,
            "CloseLid needs your password once to remove the sudoers rule it installed. This also switches back to normal sleep.")
    }

    func testInstallHelperRejectsBadUsernameBeforeAnyPrivilegedCall() {
        XCTAssertThrowsError(try sut.installHelper(username: "bad user"))
        XCTAssertTrue(privileged.scripts.isEmpty)
    }

    func testInstallHelperMapsCancel() {
        privileged.error = .cancelled
        XCTAssertThrowsError(try sut.installHelper(username: "alexwang")) { error in
            XCTAssertEqual(error as? PowerError, .cancelled)
        }
    }

    func testInstallHelperMapsFailure() {
        privileged.error = .failed("visudo: parse error")
        XCTAssertThrowsError(try sut.installHelper(username: "alexwang")) { error in
            XCTAssertEqual(error as? PowerError, .commandFailed("visudo: parse error"))
        }
    }

    func testRemoveHelperRunsRemoveScriptAndReleasesAssertion() throws {
        assertion.acquire()
        try sut.removeHelper(currentlyAwake: true)
        XCTAssertEqual(privileged.scripts, [PowerCommand.removeHelperScript])
        XCTAssertEqual(privileged.prompts, [PrivilegedPrompt.removeWhileAwake])
        XCTAssertFalse(assertion.isHeld)
    }

    func testRemoveHelperWhileNormalUsesPlainPrompt() throws {
        try sut.removeHelper(currentlyAwake: false)
        XCTAssertEqual(privileged.prompts, [PrivilegedPrompt.remove])
    }

    func testRemoveHelperMapsCancelAndKeepsAssertion() {
        assertion.acquire()
        privileged.error = .cancelled
        XCTAssertThrowsError(try sut.removeHelper(currentlyAwake: true)) { error in
            XCTAssertEqual(error as? PowerError, .cancelled)
        }
        XCTAssertTrue(assertion.isHeld)
    }
}
