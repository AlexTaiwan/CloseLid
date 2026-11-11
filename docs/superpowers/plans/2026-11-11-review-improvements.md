# CloseLid — Review and Improvement Plan

**Date:** 2026-11-11
**Reviewed commit:** `9143dc5` (main, clean tree)
**Baseline:** 100 tests, 0 failures
**For the executor:** tasks in section (d) are mechanical. Do them in order, one at a time. Every code block was applied to a copy of this repo and the full suite passed after each task (105 → 111 → 119 → 123 tests).

---

## (a) Verdict

CloseLid does what it was asked to do on AC power: one click flips `pmset -a disablesleep`, the menu shows what `pmset -g` really reports, and the sudoers rule is as narrow as that mechanism allows. It does **not** yet fully meet the underlying need — "let agents keep working with the lid closed, safely" — on battery. The only battery protection is a line of menu text, which nobody can read with the lid closed, so a closed MacBook on battery runs until a forced shutdown and the agents' work is lost rather than suspended. At review time the machine was in exactly that state: `SleepDisabled 1`, on battery, discharging. The quit path also fails open: if the last `pmset -g` read fails, or the revert itself fails, the Mac is left awake and nothing is logged. Tasks 1-3 add a low-battery guard that restores normal sleep at 10%; Task 4 makes the quit path fail safe. Both are small and unit-tested. One thing about the guard is **not verified**: whether a Mac whose lid is *already closed* actually goes to sleep once the flag is cleared (the lid event has already happened). That needs one hardware test, listed first in (e), and until it passes Tasks 1-3 address F1 rather than close it. Crash/force-kill recovery and thermal protection also need a human decision; see (e).

---

## (b) Requirement table

| # | Requirement (source) | Status | Evidence |
|---|---|---|---|
| 1 | Keep the Mac running with the lid closed via `disablesleep` (spec §1) | Met | `Sources/CloseLid/Core/PowerCommand.swift:17-19`, `Sources/CloseLid/System/PowerController.swift:66-79`; hardware-verified in spec §10.1 |
| 2 | Two clicks, no dialogs after setup (spec §1, §3) | Met | `Sources/CloseLid/App/MenuView.swift:31-35`, `sudo -n` in `PowerCommand.swift:18` |
| 3 | Always show the real state, read back from `pmset -g` (spec §3) | Met | read-back in `PowerController.swift:72-77`; 20 s re-read in `AppState.swift:70-80`. The menu can be up to 20 s stale; acceptable |
| 4 | Revert to Normal on quit, opt-out preference (spec §3, §5) | Partially met | `AppState.swift:217-227`. Works for Quit, logout and SIGTERM (`AppDelegate.swift:36-43`). Fails open when the fresh read fails (`QuitPolicy.swift:4-6`), swallows a failed revert without a log line (`AppState.swift:226`), and cannot cover SIGKILL, crash, panic or power loss (`AppDelegate.swift:38`) |
| 5 | Show power source and warn on battery (spec §3, §7) | Partially met | `MenuView.swift:79-85` is text only. It is invisible with the lid closed, which is the only time it matters. No charge is read at all (`PmsetParser.swift:25-29`) |
| 6 | Install / remove the sudoers rule (spec §4) | Met | rule text `SudoersRule.swift:18-28` (current user only, two exact command lines, username validated); install validated with `visudo -c` and copied `0440 root:wheel` (`PowerCommand.swift:24-38`); removal reverts first under `set -eu` (`PowerCommand.swift:44-48`); script inlined, not run from a temp file (`PrivilegedRunner.swift:28-37`) |
| 7 | Failures of user actions are shown (spec §7) | Met | `AppState.swift:196-201`, `AppDelegate.swift:60-78` |
| 8 | Background and quit-time failures leave a trace (spec §7, README "Diagnosing") | Partially met | mode changes and toggles are logged (`AppState.swift:125`, `:142`); the quit-time revert is not (`AppState.swift:226`) |
| 9 | Only one copy owns the flag (README) | Met | `InstanceGuard.swift:30-32`, `AppDelegate.swift:20-32`, `AppState.swift:210-219` |
| 10 | Launch at Login (README) | Met | `LoginItem.swift:19-31`, `AppState.swift:181-189`. By design it does not switch Keep Awake back on |
| 11 | Lock-screen delay row with a link to Settings (commit `9143dc5`) | Met | `ScreenLock.swift:30-48`, `MenuView.swift:51-54` |
| 12 | CLI-buildable and unit-testable without sudo (spec §3, §8) | Met | 100 tests pass; hosted tests never touch the real flag (`AppDelegate.swift:13`, `:47`) |
| 13 | Underlying need: agents keep working, and the machine is not harmed doing it | Met on AC; **not met on battery** | see finding F1 |

---

## (c) Findings, ranked

**F1 — High. Nothing protects the battery once the lid is closed.**
`disablesleep 1` blocks sleep and hibernation, so on battery the Mac runs until a forced shutdown. The app's only response is the sentence in `MenuView.swift:82`. In the scenario the app exists for (lid closed, possibly in a bag) nobody reads it. A forced shutdown loses every agent session; a sleep at 10% would have kept them in memory. Observed live during this review: `SleepDisabled 1`, `Now drawing from 'Battery Power'`, discharging.
→ Tasks 1-3 restore normal sleep at 10%. Unverified: whether an already-closed Mac then sleeps without the lid being opened and closed again — see (e) item 1.

**F2 — Medium. The quit path fails open, silently.**
`prepareForQuit` re-reads `pmset -g` and reverts only on a positive "awake" (`AppState.swift:223-225`, `QuitPolicy.swift:5`). If that one read fails, the Mac stays awake after the app is gone. If the revert itself fails (rule removed behind the app's back), `try?` at `AppState.swift:226` discards the error and no log line exists. `disablesleep 0` is idempotent, so reverting on an unreadable state costs nothing. This reverses a documented decision ("Only acts when we positively know the Mac is in Awake mode", `QuitPolicy.swift:2`) and the test that pins it (`QuitPolicyTests.testDoesNotTouchSystemWhenStateUnknown`); the task changes both on purpose.
→ Task 4.

**F3 — Medium. A crash, Force Quit (SIGKILL), kernel panic or power loss leaves the flag on with no app running.**
The flag is persisted by `powerd` (spec §1). The only recovery is the user relaunching the app and noticing the icon. Documented in the README, not mitigated. A real fix needs a watchdog outside the app process → needs human, section (e).

**F4 — Medium, unverified. The 20 s timer may be throttled with the lid closed.**
`AppState.swift:73` uses a plain `Timer` in an `LSUIElement` app with no windows, which is eligible for App Nap. The battery guard in Task 3 rides on that timer. A delay of minutes is harmless for a 10% threshold, but whether it fires at all with the lid closed can only be confirmed on hardware → section (e).

**F5 — Low. No thermal protection.** Covered only by a README caveat. A naive `ProcessInfo.thermalState` guard would fire during normal heavy local-model work and defeat the app → needs a policy decision, section (e).

**F6 — Low. Every command runs synchronously on the main thread with no timeout** (`ShellRunner.swift:37-39`). A hung `pmset` or `sysadminctl` freezes the menu and stalls quit. A blanket timeout is wrong because the same runner waits on the admin-password dialog → section (e).

**F7 — Low. A failed probe can erase a user-action error row.** `refreshPowerOnly` overwrites `lastError` and marks it probe-origin (`AppState.swift:109-110`), so the next good tick clears it (`:103`). The alert was already shown, so nothing is lost that the user did not see. Not worth a task.

**F8 — Low. `installHelperScript` leaves `/tmp/closelid.XXXXXX` behind when `visudo` rejects the rule** (`PowerCommand.swift:28-36`, `set -e` exits before `rm`). Root-owned, mode 0440, contains only the rule text. Not worth a task.

**Checked and found correct:** sudoers rule scope and grammar; username validation (`\z` anchor); inlined privileged script (no TOCTOU); `set -eu` ordering in removal; read-back after every write; second-instance stand-down not reverting on its way out; hosted tests never touching the real flag. The residual risk of option B is inherent: any process running as the user can flip this one flag without a password.

---

## (d) Tasks for the executor

### Rules for every task

1. Work only in `/Users/alexwang/Close_Lid`. Change only the files a task names.
2. Each edit is given as **Find** / **Replace with**. The Find text occurs exactly once in the file. Replace it exactly; keep indentation (4 spaces, no tabs). Strings contain typographic characters (— “ ” … ›): copy them exactly, do not retype them as ASCII.
3. After each task run the test command below. Do not start the next task until it prints `** TEST SUCCEEDED **` and the expected test count.
4. **Do not run `scripts/build.sh` and do not open or quit `build/CloseLid.app`.** A copy of the app is running from that path and `build.sh` deletes it. The test command below uses a separate build directory and never changes the real sleep setting.
5. Do not commit unless the person who gave you this plan says so. A commit message is suggested per task.

### Test command (run from the repo root)

```sh
cd /Users/alexwang/Close_Lid && xcodegen generate && xcodebuild -scheme CloseLid -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS' test 2>&1 | grep -v linkd | grep -E "error:|: failed|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" | tail -20
```

`xcodegen generate` must run every time because Task 2 adds new files. Baseline output ends with `Executed 100 tests, with 0 failures` and `** TEST SUCCEEDED **`.

---

### Task 1 — Read the battery charge from the existing `pmset -g batt` output

No new command is run; the charge is parsed from text the app already fetches. Expected after this task: **105 tests, 0 failures**.

**Edit 1.1**

File: `Sources/CloseLid/Core/PmsetParser.swift`

Find:

```swift
        if text.contains("'Battery Power'") { return .battery }
        return .unknown
    }
}
```

Replace with:

```swift
        if text.contains("'Battery Power'") { return .battery }
        return .unknown
    }

    /// Parses the charge from `pmset -g batt` output, e.g.
    /// " -InternalBattery-0 (id=1234)\t87%; discharging; 5:10 remaining present: true".
    /// - Returns: 0...100, or `nil` when there is no internal battery line (a desktop
    ///   Mac, or unreadable output). `nil` must never be read as "empty".
    static func batteryPercent(fromBattery text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) where line.contains("InternalBattery") {
            guard let percentIndex = line.firstIndex(of: "%") else { return nil }
            let digits = String(line[..<percentIndex].reversed().prefix(while: { $0.isASCII && $0.isNumber }).reversed())
            guard let value = Int(digits), (0...100).contains(value) else { return nil }
            return value
        }
        return nil
    }
}
```

**Edit 1.2**

File: `Sources/CloseLid/Core/PowerMode.swift`

Find:

```swift
    var sleepDisabled: Bool?
    var powerSource: PowerSource
```

Replace with:

```swift
    var sleepDisabled: Bool?
    var powerSource: PowerSource
    /// Internal battery charge, 0...100. `nil` when unknown or there is no battery.
    /// Defaulted so `PmsetSnapshot(sleepDisabled:powerSource:)` keeps compiling.
    var batteryPercent: Int? = nil
```

**Edit 1.3**

File: `Sources/CloseLid/System/PowerController.swift`

Find:

```swift
        let snapshot = PmsetSnapshot(
            sleepDisabled: sleepDisabled,
            powerSource: battery?.status == 0
                ? PmsetParser.powerSource(fromBattery: battery!.stdout) : .unknown
        )
```

Replace with:

```swift
        let batteryText = battery?.status == 0 ? battery?.stdout : nil
        let snapshot = PmsetSnapshot(
            sleepDisabled: sleepDisabled,
            powerSource: batteryText.map(PmsetParser.powerSource(fromBattery:)) ?? .unknown,
            batteryPercent: batteryText.flatMap(PmsetParser.batteryPercent(fromBattery:))
        )
```

**Edit 1.4 (tests)**

File: `Tests/CloseLidTests/PmsetParserTests.swift`

Find:

```swift
    func testSnapshotModeMapping() {
```

Replace with:

```swift
    func testBatteryPercentFromRealLines() {
        let discharging = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t87%; discharging; 5:10 remaining present: true\n"
        XCTAssertEqual(PmsetParser.batteryPercent(fromBattery: discharging), 87)
        let full = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t100%; charged; 0:00 remaining present: true\n"
        XCTAssertEqual(PmsetParser.batteryPercent(fromBattery: full), 100)
        let low = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t5%; discharging; (no estimate) present: true\n"
        XCTAssertEqual(PmsetParser.batteryPercent(fromBattery: low), 5)
    }

    func testBatteryPercentIsNilWithoutABatteryLine() {
        XCTAssertNil(PmsetParser.batteryPercent(fromBattery: ""))
        XCTAssertNil(PmsetParser.batteryPercent(fromBattery: "Now drawing from 'AC Power'\n"))
        XCTAssertNil(PmsetParser.batteryPercent(fromBattery: " -InternalBattery-0 (id=1234)\tcharging\n"))
        XCTAssertNil(PmsetParser.batteryPercent(fromBattery: " -InternalBattery-0 (id=1234)\t%; charging\n"))
        XCTAssertNil(PmsetParser.batteryPercent(fromBattery: " -InternalBattery-0 (id=1234)\t250%; charging\n"))
    }

    func testSnapshotBatteryPercentDefaultsToNil() {
        XCTAssertNil(PmsetSnapshot(sleepDisabled: true, powerSource: .battery).batteryPercent)
    }

    func testSnapshotModeMapping() {
```

**Edit 1.5 (tests)**

File: `Tests/CloseLidTests/PowerControllerTests.swift`

Find:

```swift
    func testProbeSyncsAssertionToSystemState() throws {
```

Replace with:

```swift
    func testProbeReportsBatteryPercent() throws {
        enqueueProbe(settings: settingsAwake,
                     batt: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t42%; discharging; 3:00 remaining present: true\n")
        let snap = try sut.probe()
        XCTAssertEqual(snap, PmsetSnapshot(sleepDisabled: true, powerSource: .battery, batteryPercent: 42))
    }

    func testProbeBatteryFailureLeavesPercentNil() throws {
        shell.enqueue(PowerCommand.probeSettings, stdout: settingsAwake)
        shell.enqueue(PowerCommand.probeBattery, status: 1, stdout: " -InternalBattery-0 (id=1234)\t42%; discharging\n")
        XCTAssertNil(try sut.probe().batteryPercent)
    }

    func testProbeSyncsAssertionToSystemState() throws {
```

**Verify:** run the test command. Expect `Executed 105 tests, with 0 failures`.
**Suggested commit:** `feat(core): parse battery charge from pmset -g batt`

---

### Task 2 — Add the pure battery-guard policy

Two new files, no existing file changes. Expected after this task: **111 tests, 0 failures**.

**Edit 2.1**

Create file: `Sources/CloseLid/Core/BatteryGuard.swift`

```swift
/// Decides when Keep Awake must switch itself off to protect the battery, and the
/// wording that goes with it. Pure; no I/O.
///
/// With `disablesleep 1` a closed MacBook on battery cannot sleep or hibernate, so it
/// runs until a forced shutdown. Nobody sees the menu with the lid closed, so the app
/// has to act on its own: at or below `threshold` it restores normal sleep, and the
/// Mac sleeps with the work still in memory instead of dying.
enum BatteryGuard {
    /// Percent of charge. macOS shows its own low-battery warning at the same level.
    static let threshold = 10

    /// True only on battery with a known charge at or below the threshold.
    /// An unknown charge (`nil`) or an unknown power source is never "low".
    static func isLow(powerSource: PowerSource, batteryPercent: Int?) -> Bool {
        guard powerSource == .battery, let batteryPercent else { return false }
        return batteryPercent <= threshold
    }

    /// True when the guard has positive evidence that the battery is no longer low:
    /// on AC, or a known charge above the threshold. Unknown readings are not evidence.
    static func isRecovered(powerSource: PowerSource, batteryPercent: Int?) -> Bool {
        if powerSource == .ac { return true }
        guard let batteryPercent else { return false }
        return batteryPercent > threshold
    }

    static func shouldRevert(mode: PowerMode, powerSource: PowerSource, batteryPercent: Int?) -> Bool {
        mode == .awake && isLow(powerSource: powerSource, batteryPercent: batteryPercent)
    }

    /// The power-source row of the menu.
    static func menuLine(powerSource: PowerSource, batteryPercent: Int?) -> String {
        switch powerSource {
        case .ac:
            return "On AC power"
        case .unknown:
            return "Power source unknown"
        case .battery:
            guard let batteryPercent else {
                return "On battery — Keep Awake will run it down to empty"
            }
            if batteryPercent <= threshold {
                return "On battery (\(batteryPercent)%) — too low, Keep Awake will run it down to empty"
            }
            return "On battery (\(batteryPercent)%) — Keep Awake switches off at \(threshold)%"
        }
    }

    /// Menu row left behind after the guard has switched Keep Awake off.
    static func notice(percent: Int) -> String {
        "Keep Awake switched itself off at \(percent)% battery"
    }
}
```

**Edit 2.2 (tests)**

Create file: `Tests/CloseLidTests/BatteryGuardTests.swift`

```swift
import XCTest
@testable import CloseLid

final class BatteryGuardTests: XCTestCase {
    func testThresholdIsTenPercent() {
        XCTAssertEqual(BatteryGuard.threshold, 10)
    }

    func testIsLowOnlyOnBatteryAtOrBelowThreshold() {
        XCTAssertTrue(BatteryGuard.isLow(powerSource: .battery, batteryPercent: 10))
        XCTAssertTrue(BatteryGuard.isLow(powerSource: .battery, batteryPercent: 0))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .battery, batteryPercent: 11))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .ac, batteryPercent: 5))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .unknown, batteryPercent: 5))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .battery, batteryPercent: nil),
                       "an unknown charge must never be treated as empty")
    }

    func testIsRecoveredNeedsPositiveEvidence() {
        XCTAssertTrue(BatteryGuard.isRecovered(powerSource: .ac, batteryPercent: 5))
        XCTAssertTrue(BatteryGuard.isRecovered(powerSource: .ac, batteryPercent: nil))
        XCTAssertTrue(BatteryGuard.isRecovered(powerSource: .battery, batteryPercent: 11))
        XCTAssertFalse(BatteryGuard.isRecovered(powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.isRecovered(powerSource: .battery, batteryPercent: nil))
        XCTAssertFalse(BatteryGuard.isRecovered(powerSource: .unknown, batteryPercent: nil))
    }

    func testShouldRevertOnlyWhenAwakeAndLow() {
        XCTAssertTrue(BatteryGuard.shouldRevert(mode: .awake, powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .normal, powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .unknown, powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .awake, powerSource: .battery, batteryPercent: 11))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .awake, powerSource: .ac, batteryPercent: 5))
    }

    func testMenuLine() {
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .ac, batteryPercent: 80), "On AC power")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .unknown, batteryPercent: nil), "Power source unknown")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .battery, batteryPercent: nil),
                       "On battery — Keep Awake will run it down to empty")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .battery, batteryPercent: 42),
                       "On battery (42%) — Keep Awake switches off at 10%")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .battery, batteryPercent: 8),
                       "On battery (8%) — too low, Keep Awake will run it down to empty")
    }

    func testNotice() {
        XCTAssertEqual(BatteryGuard.notice(percent: 10), "Keep Awake switched itself off at 10% battery")
    }
}
```

**Verify:** run the test command. Expect `Executed 111 tests, with 0 failures`.
**Suggested commit:** `feat(core): battery guard policy and menu wording`

---

### Task 3 — Wire the battery guard into the app and the menu

Behaviour being added, so nothing is left to decide:

- Every 20 s tick, after the normal re-read: if Keep Awake is on, the Mac is on battery and the charge is ≤ 10%, the app runs `disablesleep 0`, which restores normal sleep behaviour. Whether a Mac whose lid is already closed then goes to sleep by itself is not verified (section (e), item 1); this task does not try to force it.
- It leaves the row "Keep Awake switched itself off at N% battery" at the top of the menu until the next successful toggle.
- It never shows an alert (background path). If the revert fails it writes an error row and a log line, and tries again only when the charge has dropped further.
- If the user switches Keep Awake back on while still at or below 10%, that is respected: the guard stays off until the Mac is on AC or above 10%, then arms again.
- The same check runs once at launch.
- A second copy of the app (stood down) never runs it.

Expected after this task: **119 tests, 0 failures**.

**Edit 3.1**

File: `Sources/CloseLid/App/AppState.swift`

Find:

```swift
    private(set) var powerSource: PowerSource = .unknown
    private(set) var helperInstalled = false
```

Replace with:

```swift
    private(set) var powerSource: PowerSource = .unknown
    /// Internal battery charge, 0...100; `nil` when unknown or there is no battery.
    private(set) var batteryPercent: Int?
    /// Set when the battery guard switched Keep Awake off, so the reason is still on
    /// the menu when the lid is opened again. Cleared by the next successful toggle.
    private(set) var batteryGuardNotice: String?
    private(set) var helperInstalled = false
```

**Edit 3.2**

File: `Sources/CloseLid/App/AppState.swift`

Find:

```swift
    private var lastErrorIsFromProbe = false

    init(controller: PowerController, defaults: UserDefaults, username: String, loginItem: LoginItemManaging) {
```

Replace with:

```swift
    private var lastErrorIsFromProbe = false
    /// True after the user switched Keep Awake on by hand while the battery was already
    /// low. The guard then stays out of the way until the battery has recovered.
    private var batteryGuardOverridden = false
    /// Charge at which the guard last failed to restore normal sleep. It retries only
    /// once the charge has dropped further, so a missing sudoers rule does not produce
    /// a failing `sudo -n` every tick.
    private var batteryGuardFailedAtPercent: Int?

    init(controller: PowerController, defaults: UserDefaults, username: String, loginItem: LoginItemManaging) {
```

**Edit 3.3**

File: `Sources/CloseLid/App/AppState.swift`

Find:

```swift
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPowerOnly()
                // Re-read every tick: the user changes it in System Settings, not here.
                self?.refreshScreenLock()
            }
        }
    }
```

Replace with:

```swift
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
```

**Edit 3.4**

File: `Sources/CloseLid/App/AppState.swift`

Find:

```swift
            apply(try controller.setSleepDisabled(target))
            clearError()
        } catch PowerError.helperNotInstalled {
```

Replace with:

```swift
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
```

**Edit 3.5**

File: `Sources/CloseLid/App/AppState.swift`

Find:

```swift
        mode = snapshot.mode
        powerSource = snapshot.powerSource
```

Replace with:

```swift
        mode = snapshot.mode
        powerSource = snapshot.powerSource
        batteryPercent = snapshot.batteryPercent
```

**Edit 3.6**

File: `Sources/CloseLid/App/MenuView.swift`

Find:

```swift
        if let error = state.lastError {
            Text(error)
        }
```

Replace with:

```swift
        if let error = state.lastError {
            Text(error)
        }
        if let notice = state.batteryGuardNotice {
            Text(notice)
        }
```

**Edit 3.7**

File: `Sources/CloseLid/App/MenuView.swift`

Find:

```swift
        Text(powerLine)
```

Replace with:

```swift
        Text(BatteryGuard.menuLine(powerSource: state.powerSource, batteryPercent: state.batteryPercent))
```

**Edit 3.8** (removes the now-unused `powerLine`)

File: `Sources/CloseLid/App/MenuView.swift`

Find:

```swift
        URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!

    private var powerLine: String {
        switch state.powerSource {
        case .ac:      return "On AC power"
        case .battery: return "On battery — Keep Awake will run it down to empty"
        case .unknown: return "Power source unknown"
        }
    }
}
```

Replace with:

```swift
        URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!
}
```

**Edit 3.9** (layout comment at the top of the file)

File: `Sources/CloseLid/App/MenuView.swift`

Find:

```swift
///   [last error, if any]                          (disabled)
```

Replace with:

```swift
///   [last error, if any]                          (disabled)
///   Keep Awake switched itself off at 10% battery  (disabled; after the battery guard fired)
```

**Edit 3.10**

File: `Sources/CloseLid/App/MenuView.swift`

Find:

```swift
///   On AC power | On battery — Keep Awake will run it down to empty | Power source unknown
```

Replace with:

```swift
///   On AC power | On battery (42%) — Keep Awake switches off at 10% | Power source unknown
```

**Edit 3.11 (tests)**

File: `Tests/CloseLidTests/AppStateTests.swift`

Find:

```swift
    func testInstallHelperRefreshesAndClearsError() {
```

Replace with:

```swift
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
```

**Verify:** run the test command. Expect `Executed 119 tests, with 0 failures`.
**Suggested commit:** `feat(app): switch Keep Awake off at 10% battery`

---

### Task 4 — Make the quit path fail safe and leave a log line

This deliberately reverses the old rule "only revert when positively awake". New rule: on quit, revert unless the fresh read positively says "normal" or the user ticked Stay Awake After Quit. Expected after this task: **123 tests, 0 failures**.

**Edit 4.1**

File: `Sources/CloseLid/Core/QuitPolicy.swift`

Find:

```swift
/// Decides whether quitting the app should put the Mac back to normal sleep.
/// Only acts when we positively know the Mac is in Awake mode.
enum QuitPolicy {
    static func shouldRevertOnQuit(sleepDisabled: Bool?, stayAwakeAfterQuit: Bool) -> Bool {
        sleepDisabled == true && !stayAwakeAfterQuit
    }
}
```

Replace with:

```swift
/// Decides whether quitting the app should put the Mac back to normal sleep.
///
/// Fails safe: an unreadable state (`nil`) is treated like Awake. `disablesleep 0` is
/// idempotent, so reverting a Mac that was already normal changes nothing, while
/// skipping the revert on a Mac that was really awake leaves it running with the lid
/// closed and no app left to show it. Only a positive "normal" reading, or the user's
/// "Stay Awake After Quit" choice, skips the revert.
enum QuitPolicy {
    static func shouldRevertOnQuit(sleepDisabled: Bool?, stayAwakeAfterQuit: Bool) -> Bool {
        sleepDisabled != false && !stayAwakeAfterQuit
    }
}
```

**Edit 4.2**

File: `Sources/CloseLid/App/AppState.swift`

Find:

```swift
        // Decide from a fresh read, never from `mode`: it can be up to one tick stale,
        // or `.unknown` after a tick that happened to fail, and either would skip the
        // revert and leave the Mac awake with the lid closed.
        refreshPowerOnly()
        let sleepDisabled: Bool? = (mode == .awake) ? true : (mode == .normal ? false : nil)
        guard QuitPolicy.shouldRevertOnQuit(sleepDisabled: sleepDisabled, stayAwakeAfterQuit: stayAwakeAfterQuit) else { return }
        _ = try? controller.setSleepDisabled(false)
    }
```

Replace with:

```swift
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
```

**Edit 4.3 (tests — replaces the test that pinned the old behaviour)**

File: `Tests/CloseLidTests/QuitPolicyTests.swift`

Find:

```swift
    func testDoesNotTouchSystemWhenStateUnknown() {
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: false))
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: true))
    }
```

Replace with:

```swift
    // Fail safe: an unreadable state reverts, unless the user asked to stay awake.
    func testRevertsWhenStateUnknownUnlessUserOptedToStayAwake() {
        XCTAssertTrue(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: false))
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: true))
    }
```

**Edit 4.4 (tests)**

File: `Tests/CloseLidTests/AppStateTests.swift`

Find:

```swift
    // A second copy of the app must never touch the flag: the first copy owns it.
```

Replace with:

```swift
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
```

**Verify:** run the test command. Expect `Executed 123 tests, with 0 failures`.
**Suggested commit:** `fix(app): revert on quit when the state is unreadable; log the quit-time revert`

---

### Task 5 — Bring the README and the spec in line with Tasks 3 and 4

Documentation only. Expected after this task: still **123 tests, 0 failures**.

**Edit 5.1**

File: `README.md`

Find:

```markdown
| On AC power / On battery — … | Power source. On battery, Keep Awake runs the Mac down to empty, so the line says so in both states. |
```

Replace with:

```markdown
| On AC power / On battery (42%) — … | Power source and charge. On battery, Keep Awake switches itself off when the charge reaches 10%, so normal sleep is back before the battery is empty; a line at the top of the menu says so afterwards. If you switch it back on below 10%, that is respected until you plug in. |
```

**Edit 5.2**

File: `README.md`

Find:

```markdown
- On battery, Awake mode drains until forced shutdown. Plug in.
```

Replace with:

```markdown
- On battery, Awake mode drains the battery to 10% and then switches itself off, restoring normal sleep. Your agents stop being protected at that point, so plug in for long runs. The check runs about every 20 seconds while the app is running; if the app has quit with *Stay Awake After Quit* ticked, nothing is watching the battery.
```

**Edit 5.3**

File: `README.md`

Find:

```markdown
quitting the app — including at logout or a restart — switches sleep back to normal.
```

Replace with:

```markdown
quitting the app — including at logout or a restart — switches sleep back to normal
(also when the app cannot read the current setting at that moment).
```

**Edit 5.4**

File: `docs/superpowers/specs/2026-09-02-close-lid-design.md`

Find:

```markdown
   the README should say so. Not a software concern.
```

Replace with:

```markdown
   the README should say so. Not a software concern.

## 11. Amendments (2026-11-11 review)

The code supersedes the text above in these places
(plan: `docs/superpowers/plans/2026-11-11-review-improvements.md`):

1. **§3 and §7 "On battery".** Still allowed, but no longer left to run to empty.
   `BatteryGuard` restores normal sleep when Keep Awake is on, the Mac is on battery
   and the charge is at or below 10%. It leaves a menu row saying so, never a modal.
   A manual re-enable below 10% is respected until the Mac is on AC or above 10%.
   The power line shows the charge: "On battery (42%) — Keep Awake switches off at 10%".
2. **§5 "Quit".** `QuitPolicy` now fails safe: it reverts unless the fresh read
   positively says normal sleep, or "Stay Awake After Quit" is ticked. An unreadable
   state reverts. The quit-time revert and its failure are logged.
3. **§5 "Quit", Force Quit.** Activity Monitor's *Quit* sends SIGTERM and reverts;
   *Force Quit* sends SIGKILL and cannot be handled. Launch reconciliation covers it.
```

**Verify:** run the test command. Expect `Executed 123 tests, with 0 failures`.
**Suggested commit:** `docs: battery guard and fail-safe quit`

---

## (e) Recommended, needs a human

These were left out of (d) because they need a password, a real lid close, a product decision, or a redesign.

1. **Does an already-closed Mac sleep when the flag is cleared? (decides whether F1 is closed).** Not established anywhere in this review. Test on AC or battery: enable Keep Awake, close the lid, then from another machine over ssh run `sudo pmset -a disablesleep 0`, wait two minutes, reopen and check `pmset -g log | grep "Entering Sleep state"` for an entry in that window. Idle sleep is not a reliable backstop: this machine's `pmset -g` shows `sleep 0`, and agent tools often hold their own idle-sleep assertions. If no sleep entry appears, the guard needs a follow-up: after a successful revert, when the lid is closed (`ioreg -r -k AppleClamshellState -d 4 | grep AppleClamshellState` reports `Yes`), run `/usr/bin/pmset sleepnow`, which needs no root. That follow-up adds a new command to the tick path and must be hardware-tested, so it is not in (d).
2. **Hardware check of the battery guard's timer with the lid closed (F4).** Confirm the 20 s timer still fires with the lid closed and the app in the background (App Nap). Test: enable Keep Awake on battery, close the lid for 10 minutes, then check `log show --last 15m --predicate 'subsystem == "com.alexwang.CloseLid"'` together with a heartbeat loop as in the README. If ticks are missing, wrap the awake period in `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)` or move the timer to a `DispatchSourceTimer` with strict leeway, and re-test.
3. **End-to-end check of the guard itself.** Let the battery reach 10% with Keep Awake on (or temporarily raise `BatteryGuard.threshold` in a local build) and confirm the Mac sleeps and the menu row appears on reopening.
4. **Crash / Force Quit / panic recovery (F3).** The flag outlives the app. Options, all needing a design decision: a small LaunchAgent watchdog that runs `sudo -n pmset -a disablesleep 0` when the app is not running and "Stay Awake After Quit" is off; or reverting at launch when the previous run did not exit cleanly. Either changes what "leftover Awake state" means in spec §5.
5. **Threshold and "AC only" as preferences.** 10% is hard-coded. Decide whether it should be adjustable, and whether to offer "Keep Awake only while on AC power" (switch off as soon as the charger is unplugged), which is the stronger protection for the lid-closed-in-a-bag case.
6. **Thermal protection (F5).** Decide a policy first. `ProcessInfo.thermalState == .critical` is a candidate trigger, but heavy local-model work raises thermal state with the lid open too, so `.serious` would defeat the app. Needs a real closed-lid heat test.
7. **Timeouts for system commands (F6).** Add a per-call timeout for `pmset` / `sysadminctl` / `sudo -n` only. It must not apply to the `osascript` call, which legitimately waits on the password dialog. Consider moving probes off the main thread at the same time.
8. **Move the running copy to `/Applications`.** The copy running at review time is `build/CloseLid.app`. `scripts/build.sh` deletes that path on every build, and Launch at Login registers whatever path the app ran from. Quit it, copy the new build to `/Applications`, relaunch from there, and re-tick Launch at Login.
9. **Sudoers rule is unchanged by this plan.** No reinstall or password is needed for Tasks 1-5. If the rule is ever revisited: any process running as the user can flip this flag silently; removing that needs the `SMAppService` helper the spec rejected (option C).
10. **Manual gate still open from the original plan:** quit while Awake with "Stay Awake After Quit" off, and confirm `pmset -g` shows `SleepDisabled 0`. After Task 4, also confirm the log shows `quit: normal sleep restored`.
