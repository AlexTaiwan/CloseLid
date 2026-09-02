# CloseLid

A tiny macOS menu bar switch that keeps your MacBook running with the lid closed,
so long-running LLM agents (Claude Code, local model servers, …) are not frozen
by sleep. One click on, one click off.

## Why not `caffeinate`?

`caffeinate` and power assertions only stop *idle* sleep. Closing the lid still
sleeps a MacBook. The only software switch that prevents that is the root-only
power-management flag `pmset -a disablesleep 1`. This app flips exactly that flag.

## Requirements

- macOS 14 or later, Apple Silicon or Intel MacBook.
- Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build.

## Build

```sh
scripts/build.sh          # produces build/CloseLid.app
open build/CloseLid.app
cp -R build/CloseLid.app /Applications/   # recommended: a stable path for Launch at Login
```

## First run: install the sudoers rule (one admin password, once)

Because `pmset disablesleep` needs root, the app installs a single sudoers
drop-in at `/etc/sudoers.d/closelid` containing only:

```
<your-username> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

The file is validated with `visudo -c` before it is copied into place. Nothing
else is granted. After that, toggling is silent.

Menu → **Install Sudoers Rule…** → enter your password in the system dialog (it names CloseLid and says what it installs).

## Use

| Menu item | Meaning |
|---|---|
| Keep Awake with Lid Closed | Checkmark item; click to toggle. The menu bar icon is a laptop normally and a coffee cup while awake. A laptop with a warning badge means the app could not read the sleep setting. |
| On AC power / On battery — … | Power source. On battery, Keep Awake runs the Mac down to empty, so the line says so in both states. |
| Launch at Login | Registers the app as a macOS login item. If macOS asks for approval, a line under the item points you to System Settings › Login Items. Keep the app in /Applications so the registered path stays valid. |
| Stay Awake After Quit | By default quitting the app restores normal sleep. Tick this to leave the flag on. |
| Remove Sudoers Rule… | Restores normal sleep and deletes `/etc/sudoers.d/closelid`. The password dialog tells you when this will also switch you back to normal sleep. |

If a toggle fails, CloseLid shows a native alert with the reason, and the same text stays at the top of the menu until the next successful action.

The app always re-reads `pmset -g` after every change and shows what the system
actually reports. If the app crashes while Awake, the flag stays on (macOS
persists it); relaunching shows the true state so you can switch it off.

## Uninstall

1. Menu → **Remove Sudoers Rule…** (admin password).
2. Quit the app and delete `CloseLid.app`.
3. Manual fallback if you skipped step 1: `sudo pmset -a disablesleep 0` and
   `sudo rm /etc/sudoers.d/closelid`.

## Caveats

- A closed MacBook on a soft surface can run hot. Leave it on a hard surface.
- On battery, Awake mode drains until forced shutdown. Plug in.
