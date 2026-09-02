# CloseLid — Design Spec

**Date:** 2026-09-02
**Status:** Draft, awaiting user approval
**Project dir:** `/Users/alexwang/Close_Lid`

## 1. Problem

When a MacBook lid is closed, macOS puts the machine to sleep. Any long-running
LLM agent sessions (Claude Code, local model servers, etc.) are frozen until the
lid is reopened. The user wants a **menu bar toggle**: open the menu, click
"Keep Awake with Lid Closed", and click it again to return to normal sleep. Two
clicks, no dialogs.

`caffeinate` and IOKit power assertions do **not** prevent lid-close sleep on a
MacBook. They only prevent *idle* sleep. The only supported software switch that
keeps a MacBook running with the lid closed (no external display required) is
the root-only power-management flag:

```
sudo pmset -a disablesleep 1   # keep awake with lid closed
sudo pmset -a disablesleep 0   # restore normal behaviour
```

This is what the app must drive. The flag is present in `/usr/bin/pmset` on the
user's machine (macOS 26.5.2, Apple Silicon) though it is absent from the man
page. It is persisted by `powerd` and survives app crashes and reboots, which
drives several requirements below.

## 2. Assumptions (user to confirm or override)

1. **Personal / developer use**, distributed as a locally built `.app`, not via
   the Mac App Store. App Sandbox is off. Ad-hoc codesigning is fine.
2. **Deployment target macOS 14 (Sonoma)** or later; built with Xcode 26 /
   Swift 6.2 already installed.
3. **Privilege model: one-time sudoers rule** (see §4). The user accepts a
   single admin-password prompt at install time in exchange for silent toggles
   afterwards.
4. The app is **not** responsible for keeping the display on, sessions alive
   across reboots, or preventing thermal throttling. It flips one flag and
   reports state honestly.
5. Name: **CloseLid** (bundle id `com.alexwang.CloseLid`). Rename is trivial.

## 3. Goals and non-goals

**Goals**

- Menu bar icon with two states, visually distinct at a glance.
- Single-click toggle between *Awake* and *Normal*.
- Always reflect the **real** system state on launch and after each toggle,
  read back from `pmset -g` rather than from app memory.
- Revert to *Normal* on app quit by default, with an opt-out preference
  ("Stay awake after quit").
- Show current power source (AC / battery) and warn when enabling Awake on
  battery, because a closed MacBook on battery will run until a hard shutdown.
- Provide **Install helper** / **Remove helper** actions for the sudoers rule.
- Fully CLI-buildable and unit-testable without sudo.

**Non-goals (YAGNI)**

- Timers / "keep awake for N minutes".
- Launch-at-login (can be added later with `SMAppService` in a few lines).
- Custom icons, themes, hotkeys.
- App Store distribution, notarization, sandboxing.
- Preventing display sleep or screen lock.

## 4. Privilege model

Three options were considered:

| Option | Mechanism | Trade-off |
|---|---|---|
| A | `osascript … with administrator privileges` per toggle | Zero install, but a password dialog on every flip — defeats "quick switch". |
| **B (chosen)** | One-time `/etc/sudoers.d/closelid` granting `NOPASSWD` for exactly two commands | One admin prompt ever; toggles are silent via `sudo -n`. Simple, inspectable, removable. |
| C | `SMAppService` privileged helper + XPC | The "proper" Apple way, but a lot of machinery for a one-flag utility. |

**Sudoers rule content** (installed with the user's short name substituted):

```
# Installed by CloseLid.app — allows toggling lid-close sleep without a password
alexwang ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

Scope is the **current user only**, never `%admin`. The two command lines are
fully specified so no other `pmset` invocation is permitted.

**Install flow** (one admin prompt, via `osascript … with administrator
privileges` running a single shell command):

1. Write the rule to a temp file.
2. Validate with `visudo -c -f <tmp>`; abort on failure.
3. `install -m 0440 -o root -g wheel <tmp> /etc/sudoers.d/closelid`.

**Remove flow**: `rm -f /etc/sudoers.d/closelid` (also privileged prompt), then
revert `disablesleep` to 0 first so the machine is never left stuck awake without
a way to switch back silently.

**Helper detection**: `sudo -n -l /usr/bin/pmset -a disablesleep 1` exits 0 when
the rule is present. The menu shows "Install helper…" until it is.

## 5. Architecture

```
CloseLid.app (SwiftUI, MenuBarExtra, LSUIElement)
│
├── App/                    CloseLidApp.swift        @main, MenuBarExtra, quit hook
│                           MenuView.swift           menu contents
│                           AppState.swift           @Observable view-model
│
├── Core/  (pure, no I/O — fully unit tested)
│       PowerMode.swift         enum PowerMode { normal, awake }
│       PmsetParser.swift       parse `pmset -g` text -> SleepDisabled flag, power source
│       PowerCommand.swift      builds exact argv for enable/disable/probe/install/remove
│       SudoersRule.swift       renders the sudoers text for a given username
│       QuitPolicy.swift        decides whether to revert on quit given prefs + state
│       PrivilegedPrompt.swift  the sentences shown in the admin-password dialog
│
├── System/ (thin I/O adapters)
│       ShellRunner.swift       protocol ShellRunning { run(argv) -> (status, stdout, stderr) }
│       ProcessShellRunner      real implementation using Foundation.Process
│       PrivilegedRunner.swift  runs a shell script via osascript "with administrator privileges
│                               with prompt <sentence naming CloseLid>" so the password dialog is
│                               not attributed to "osascript"
│       PowerController.swift   orchestrates: probe state, toggle, install/remove helper,
│                               holds an IOPMAssertion while Awake (belt-and-braces vs idle sleep)
│       (power source is read from `pmset -g batt` on every refresh; no IOKit monitor)
│
└── Tests/  CloseLidTests      fixture-string tests for Core/ and a MockShellRunner
                               driving PowerController
```

**Data flow for a toggle**

1. User clicks "Keep Awake" → `AppState.toggle()`.
2. `PowerController.set(.awake)` runs `sudo -n /usr/bin/pmset -a disablesleep 1`
   through `ShellRunner`.
3. On non-zero exit (rule missing), controller returns `.helperNotInstalled`;
   UI shows the Install prompt instead of pretending it worked.
4. Controller re-probes with `pmset -g`, parses `SleepDisabled 1`, publishes the
   new mode. The icon changes only after the read-back confirms it.
5. While in Awake, controller also creates
   `kIOPMAssertionTypePreventUserIdleSystemSleep` (released on Normal). This is
   harmless if `disablesleep` already covers idle sleep and protective if it does
   not.

**Launch**: probe real state, reconcile UI. If the system says Awake but the
app just started, that is a leftover from a crash or a "stay awake after quit"
choice; show it as Awake (truthfully) and let the user decide.

**Quit**: `NSApplication.willTerminate` → `QuitPolicy` → if revert, run
`disablesleep 0` synchronously before exit. Also handled for `SIGTERM` via a
signal source so a Force Quit from Activity Monitor still reverts. Kernel
panics / power loss cannot be handled; the launch reconciliation covers those.

## 6. Menu layout

Reviewed by a macOS UI/UX design pass on 2026-09-02; the layout below is the
result. Rows marked *(disabled)* are non-interactive text; `✓` is a checked
`Toggle`. In `.menu` style, clicking any item closes the menu, so every
consequence the user must see *before* acting is shown at decision time, and
every failure of a user action is also raised as a native alert (§7).

**Normal sleep, rule installed, on AC** — icon `laptopcomputer`

```
    Keep Awake with Lid Closed
  ──────────────────────────────
    On AC power                              (disabled)
  ──────────────────────────────
    Stay Awake After Quit
    Remove Sudoers Rule…
  ──────────────────────────────
    Quit CloseLid                        ⌘Q
```

**Awake, on battery** — icon `cup.and.saucer.fill`

```
  ✓ Keep Awake with Lid Closed
  ──────────────────────────────
    On battery — Keep Awake will run it down to empty    (disabled)
  ──────────────────────────────
    Stay Awake After Quit
    Remove Sudoers Rule…
  ──────────────────────────────
    Quit CloseLid                        ⌘Q
```

**First run, rule not installed** — icon `laptopcomputer`

```
    Keep Awake with Lid Closed               (disabled)
    Not set up yet — needs a one-time admin password     (disabled)
    Install Sudoers Rule…
  ──────────────────────────────
    On AC power                              (disabled)
  ──────────────────────────────
    Stay Awake After Quit
  ──────────────────────────────
    Quit CloseLid                        ⌘Q
```

**Unknown (`pmset -g` unreadable)** — icon `laptopcomputer.trianglebadge.exclamationmark`

```
    Keep Awake with Lid Closed               (disabled)
    Could not read the sleep setting         (disabled)
  ──────────────────────────────
    Power source unknown                     (disabled)
  ──────────────────────────────
    Stay Awake After Quit
    Remove Sudoers Rule…
  ──────────────────────────────
    Quit CloseLid                        ⌘Q
```

When a user action fails, its error text is inserted as a disabled first row
until the next successful action.

Icon rules: three distinct silhouettes because the menu bar renders a
monochrome template and inverts it while open, so rendering modes and
fill-vs-outline pairs do not separate. `sun.max.fill` is avoided because it is
the system brightness glyph and this app does not touch the display. Each image
carries an accessibility label. User-visible copy says "sudoers rule", never
"helper", because to this audience "helper" means an `SMAppService` privileged
helper, which §4 rejects. Code identifiers keep `helper`.

Admin-password dialog copy (AppleScript `with prompt`), because the dialog is
otherwise attributed to "osascript":

- Install: "CloseLid needs your password once to add a sudoers rule that lets it turn lid-close sleep on and off without asking again."
- Remove: "CloseLid needs your password once to remove the sudoers rule it installed." plus, when currently awake, " This also switches back to normal sleep."

## 7. Error handling

| Situation | Behaviour |
|---|---|
| Rule not installed | Primary item is disabled and "Install Sudoers Rule…" sits directly under it, so the first-run failure cannot happen. If the rule was removed behind the app's back and a toggle fails, a native alert "CloseLid could not change the sleep setting." shows the reason and the menu switches to the not-set-up state. |
| `visudo -c` fails | Abort install, show error, leave `/etc/sudoers.d` untouched. |
| User cancels admin prompt | Silent no-op. |
| Any other failure of a user-initiated action (toggle, install, remove) | Native `NSAlert` (activate app first, next run-loop turn) with the reason, plus the same text as the first menu row. The 20 s background refresh never alerts. |
| `pmset -g` output unparseable | Treat as unknown; icon shows a "?" state, toggle disabled, log the raw text. |
| Toggle succeeded but read-back disagrees | Show read-back value; log discrepancy. Never trust the write. |
| On battery | Allowed. The power line reads "On battery — Keep Awake will run it down to empty" in both modes, so the consequence is visible before enabling. No modal. |

## 8. Testing

- **Unit (no sudo):** `PmsetParser` against captured `pmset -g` fixtures
  (AC, battery, SleepDisabled present/absent, garbage). `PowerCommand` argv
  exactness. `SudoersRule` output byte-exact. `QuitPolicy` truth table.
  `PowerController` against `MockShellRunner` for success, helper-missing, and
  read-back-mismatch paths.
- **Manual gate (Task 0, before any UI work):** user runs
  `sudo pmset -a disablesleep 1`, closes the lid for ~60 s, reopens, and checks
  `pmset -g log | grep -E " Sleep  | Wake  " | tail`. No Sleep entry ⇒ design
  holds. A Sleep entry ⇒ stop and redesign (this machine would need clamshell
  mode with an external display, which no software can substitute).
- **Manual end-to-end:** install helper, toggle Awake, close lid, `ssh`/`ping`
  from another device or watch an agent log keep advancing, reopen, toggle
  Normal, confirm `pmset -g` shows no `SleepDisabled`.

## 9. Build and distribution

- `project.yml` for **xcodegen** (installed at `/opt/homebrew/bin/xcodegen`)
  → `CloseLid.xcodeproj`. Builds with `xcodebuild -scheme CloseLid` and opens in
  Xcode 26.
- `scripts/build.sh` produces `build/CloseLid.app`, ad-hoc signed
  (`codesign -s -`).
- `Info.plist`: `LSUIElement = true` (no Dock icon), no sandbox entitlement.
- README documents: what it does, why it needs sudo, the exact sudoers line,
  how to remove everything (`Remove helper`, then delete the app, then
  `sudo pmset -a disablesleep 0` as a manual fallback).

## 10. Open risks

1. ~~Task 0 may fail~~ **Verified 2026-09-02** on MacBook Air, macOS 26.5.2 (Apple Silicon): `sudo pmset -a disablesleep 1` kept the Mac awake with the lid closed; `pmset -g` shows `SleepDisabled 1`; `/etc/sudoers` has `#includedir /private/etc/sudoers.d` (line 64).
2. Apple could remove `disablesleep` in a future macOS; the read-back design
   means the app would show "unknown" rather than lie.
3. A closed MacBook running hot on a soft surface can throttle or overheat;
   the README should say so. Not a software concern.
