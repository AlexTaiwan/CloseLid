# CloseLid — Design Spec

**Date:** 2026-09-02
**Status:** Draft, awaiting user approval
**Project dir:** `/Users/alexwang/Close_Lid`

## 1. Problem

When a MacBook lid is closed, macOS puts the machine to sleep. Any long-running
LLM agent sessions (Claude Code, local model servers, etc.) are frozen until the
lid is reopened. The user wants a **menu bar toggle**: one click to "Keep Awake
(lid closed)" and one click back to "Normal sleep".

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
│
├── System/ (thin I/O adapters)
│       ShellRunner.swift       protocol ShellRunning { run(argv) -> (status, stdout, stderr) }
│       ProcessShellRunner      real implementation using Foundation.Process
│       PrivilegedRunner.swift  runs a shell string via osascript "with administrator privileges"
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

```
● Keep Awake (lid closed)      ← or "○ Normal sleep"; click toggles
──────────────────────────────
Power: AC adapter              ← or "Power: Battery ⚠︎ will drain until shutdown"
Helper: installed              ← or "Install helper…" (action)
──────────────────────────────
☐ Stay awake after quit
Remove helper…
──────────────────────────────
Quit CloseLid                 ⌘Q
```

Menu bar icon: SF Symbols `laptopcomputer` (Normal) vs
`laptopcomputer.slash`-style filled variant or `sun.max.fill` (Awake). Exact
choice left to the UI task; the requirement is distinguishable in both light and
dark menu bars.

## 7. Error handling

| Situation | Behaviour |
|---|---|
| Helper not installed, toggle attempted | No state change; menu switches to Install prompt with one-line explanation. |
| `visudo -c` fails | Abort install, show error, leave `/etc/sudoers.d` untouched. |
| User cancels admin prompt | Silent no-op. |
| `pmset -g` output unparseable | Treat as unknown; icon shows a "?" state, toggle disabled, log the raw text. |
| Toggle succeeded but read-back disagrees | Show read-back value; log discrepancy. Never trust the write. |
| Enabling Awake on battery | Allowed, but the power line shows the ⚠︎ warning. (No modal; the user asked for a quick switch.) |

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
