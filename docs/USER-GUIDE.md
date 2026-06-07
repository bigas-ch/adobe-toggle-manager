# Adobe Toggle Manager — User Guide

## What it does

Adobe Toggle Manager keeps Adobe Creative Cloud's background components
**disabled** — the always-running daemons, the CCXProcess agent, Core Sync,
crash/telemetry reporters, and Finder/QuickLook plugin extensions that launch at
login and run even when no Adobe app is open. It blocks them **at the source**
and keeps them blocked, even after an Adobe update tries to re-enable them. You
can flip between **Block** and **Allow** at any time; your choice survives reboot
and logout.

It changes nothing about Adobe's licensing or your files — it only manages
**auto-start and background services** of Adobe software you have legitimately
installed.

## Requirements

- **macOS 14 (Sonoma) or newer**
- **zsh** (the macOS default shell — already there)
- **Xcode Command Line Tools** *(optional, recommended)* — only used for the
  sub-second FSEvents watcher. Without them the daemon falls back to 30-second
  polling. Install once: `xcode-select --install`
- **`fzf`** *(optional)* — only for the whitelist picker: `brew install fzf`
- No paid Apple Developer account needed.

## Install

```bash
git clone https://github.com/bigas-ch/adobe-toggle-manager.git
cd adobe-toggle-manager
./install.sh
```

The installer sets up a background daemon (a macOS LaunchAgent) plus a
health-check that restarts it if it ever hangs.

**Default after install: `block`** — Adobe's background components get disabled
right away. If you'd rather install *without* blocking immediately:

```bash
ATM_INITIAL_STATE=allow ./install.sh
```

## Daily use — the TUI

Run the tool with no arguments to open the terminal UI:

```bash
./adobe-toggle
```

You'll see a status box (current state, daemon PID, how many components are
discovered/disabled, last event) and this menu:

```
[a] Allow   [b] Block   [d] Discovery   [s] Stats   [u] Sudo-Sweep   [e] Sudo-Unsweep   [w] Whitelist   [q] Exit
```

| Key | What it does |
|-----|--------------|
| **`b` Block** | Disable all Adobe background components and keep them disabled. |
| **`a` Allow** | Re-enable them (Adobe can run normally again). |
| **`d` Discovery** | Show every Adobe component the daemon currently sees. |
| **`s` Stats** | Show recent activity / counters. |
| **`u` Sudo-Sweep** | *Manually* disable the system-level Adobe services (needs Touch ID — see below). Usually automatic; this is the manual fallback. |
| **`e` Sudo-Unsweep** | *Manually* re-enable the system-level services after Allow. |
| **`w` Whitelist** | Open the `fzf` picker to mark individual components as "always allowed". |
| **`q` Exit** | Leave the TUI (the daemon keeps running in the background). |

**You normally only press `b` or `a`.** When there's system-level work that needs
admin rights, the matching sweep (after **Block**) or un-sweep (after **Allow**)
runs **automatically** right after you press the key — a single Touch ID prompt,
and only when something actually needs it.

## One-time setup: Touch ID for the system-level sweep

A few Adobe components are **system LaunchDaemons** (Adobe Genuine Service, the
ARMDC communicator, the CC installer service). Disabling those needs
administrator rights. The tool uses **Touch ID** for that instead of a typed
password — but you enable Touch ID for `sudo` once:

```bash
sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local
sudo sed -i '' 's|^# *auth|auth|' /etc/pam.d/sudo_local
```

After that, pressing **Block** (or **Allow**) simply shows a Touch ID prompt when
a system-level change is needed. If you skip this setup, the tool tells you the
system-level components are still running and what to do.

Turn the automatic sweep off entirely:

```bash
./adobe-toggle config set auto-sudo-sweep false
```

## Whitelist — keep some Adobe components allowed

Press **`w`** in the TUI to open a multi-select picker. **TAB** selects,
**ENTER** toggles the selection between *whitelisted* (always allowed) and
*auto-blocked*. Whitelisted components are never disabled, even while the global
state is **Block**. The whitelist persists across reboots. (Requires `fzf`.)

## Command line (no TUI)

```bash
./adobe-toggle status            # current state + daemon health (one line)
./adobe-toggle status --json     # same, machine-readable
./adobe-toggle discovery         # list discovered Adobe components
./adobe-toggle summary           # aggregated view (events + state + disabled)
./adobe-toggle health            # exit 0 = healthy, 1 = unhealthy
./adobe-toggle config show       # show all settings
./adobe-toggle --version
./adobe-toggle --help
```

### Settings

```bash
config set notifications off              # quieter (default: minimal)
config set auto-start-cc true             # auto-start Creative Cloud on Allow
config set auto-sudo-sweep false          # disable the automatic system-level sweep
config set adaptive-interval true         # less CPU at the cost of slower drift detection
config set tick-interval 60               # daemon poll interval in seconds
```

Unknown keys or invalid values are rejected with a clear message, so typos can't
silently do nothing.

## Uninstall

```bash
./uninstall.sh
```

It **re-enables Adobe first** (so nothing is left blocked), removes both
LaunchAgents, kills the daemon, and deletes the runtime files. Preview without
changing anything:

```bash
ATM_UNINSTALL_DRY_RUN=1 ./uninstall.sh
```

## Troubleshooting

- **A Touch ID prompt appears after Block/Allow** — expected: it's the
  system-level sweep authenticating. Approve it. (Disable with
  `config set auto-sudo-sweep false`.)
- **System-level Adobe services still running** — you haven't enabled Touch ID
  for `sudo` yet (see the one-time setup above), or you declined the prompt.
- **Whitelist key says `fzf` is missing** — `brew install fzf`.
- **No sub-second updates / "polling" mode** — install the Xcode Command Line
  Tools (`xcode-select --install`); without them the daemon polls every 30 s,
  which is still fully functional.
- **Where are the logs?** — `~/Library/Application Support/AdobeToggleManager/logs/`

---

**Disclaimer:** Adobe Toggle Manager is an independent, community-built tool. It
is **not affiliated with, endorsed by, or sponsored by Adobe Inc.** "Adobe" and
"Creative Cloud" are trademarks of Adobe Inc. It manages only the background
services of Adobe software you have legitimately installed.
