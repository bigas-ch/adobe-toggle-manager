# Adobe Toggle Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Shell: zsh](https://img.shields.io/badge/Shell-zsh-89e051.svg)](#requirements)
<!-- Enable the CI badge only after the public CI workflow has run green at least once:
[![CI](https://github.com/bigas-ch/adobe-toggle-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/bigas-ch/adobe-toggle-manager/actions/workflows/ci.yml)
-->

> An always-on macOS daemon that keeps Adobe Creative Cloud background
> components disabled — and keeps them disabled, even after Adobe updates
> silently re-enable them.

> 📖 **New here?** Start with the **[User Guide](docs/USER-GUIDE.md)** — install,
> daily use, Touch ID setup, whitelist, and troubleshooting in one place.

## What

Adobe Toggle Manager blocks Adobe Creative Cloud background processes,
LaunchAgents/LaunchDaemons, and Finder/QuickLook plugin extensions, and
holds them blocked. A lightweight terminal UI lets you flip between
**Block** and **Allow** at any time. Your choice persists across reboot
and logout.

## Why

Installing a single Adobe app drags in a swarm of always-running helpers:
Creative Cloud daemons, the CCXProcess background agent, Core Sync, Adobe
crash/telemetry reporters, and Finder/QuickLook plugin extensions. They
launch at login, consume RAM and CPU, and phone home — whether or not you
have any Adobe app open.

Disabling them by hand does not stick. Adobe ships its components as
LaunchAgents that auto-restart, and every Adobe update happily
re-enables what you turned off. Manually fighting this is whack-a-mole.

Adobe Toggle Manager solves it at the root:

- It **discovers** Adobe components dynamically by verifying each binary's
  code-signing authority (`Developer ID Application: Adobe Inc.` /
  `Adobe Systems Incorporated`) — there is no brittle hard-coded name list
  to maintain, so it survives Adobe renaming or adding components.
- It **blocks** them with `launchctl disable` (for launchd jobs) and
  `pluginkit -e ignore` (for plugin extensions) — disabling auto-start at
  the source, not just killing a running process.
- A background daemon **re-applies** the block whenever Adobe drifts back,
  with sub-second latency when the optional FSEvents watcher is active.

## Features

- **Block** — stops all running Adobe processes, disables all Adobe
  LaunchAgents and pluginkit extensions, and prevents new auto-starts.
- **Allow** — re-enables previously disabled components; optional
  auto-start for Creative Cloud.
- **Granular whitelist** — a key in the TUI opens an `fzf` multi-select
  picker; whitelisted components stay permanently allowed even while the
  global state is `block`. The whitelist persists across reboot.
- **Self-healing health probe** — a `health` subcommand plus a second
  LaunchAgent checks the daemon every few minutes and restarts it via
  `launchctl kickstart` if it is unhealthy.
- **JSON output** — `status`, `discovery`, and `summary` accept `--json`
  for monitoring integrations, with zero runtime dependencies (a pure-zsh
  encoder, no `jq`/`python` required).
- **NDJSON logging** — `jq`-pipeable structured log lines for queries.
- **Dynamic discovery** — code-signing-authority matching instead of a
  static pattern list, robust against Adobe updates.
- **Pluggable backends** — discovery backends are swappable zsh modules
  under `lib/backends/` (today: `launchd` and `pluginkit`); new macOS
  subsystems can be added without touching the core.
- **FSEvents-driven** — a small native Swift helper signals the daemon on
  file events, cutting drift-detection latency below one second; idle CPU
  is effectively zero. A 30-second polling fallback runs if the helper is
  not built.
- **State-persistent** — your last choice wins, even after reboot.
- **Hardened** — `0600` state files, TOCTOU-resistant authority caching,
  strict label validation, a fixed `PATH`, and Touch ID for the optional
  privileged sweep. See [SECURITY.md](SECURITY.md).

## Requirements

- **macOS 14 (Sonoma) or newer.**
- **zsh** — the system default shell on macOS.
- **Xcode Command Line Tools (optional, recommended).** Used only to
  compile/run the FSEvents watcher for sub-second drift detection. Without
  them, the daemon falls back to 30-second polling. Install once with
  `xcode-select --install`.
- **`fzf` (optional).** Required only for the interactive whitelist picker.
  Install with `brew install fzf`.
- No paid Apple Developer account is required.

## Install

### Option A — git clone

```bash
git clone https://github.com/bigas-ch/adobe-toggle-manager.git
cd adobe-toggle-manager
./install.sh
```

### Option B — GitHub Release tarball

Download the latest release tarball from the
[Releases page](https://github.com/bigas-ch/adobe-toggle-manager/releases),
then:

```bash
tar -xzf adobe-toggle-manager-*.tar.gz
cd adobe-toggle-manager-*
./install.sh
```

The installer compiles the Swift FSEvents helper automatically if the
Xcode Command Line Tools are present. The daemon runs correctly without it
(30-second polling fallback).

The default state after install is `block`. To install without blocking
Adobe immediately:

```bash
ATM_INITIAL_STATE=allow ./install.sh
```

## Usage

```bash
./adobe-toggle                  # open the TUI (default)
./adobe-toggle status           # state + daemon health (single line)
./adobe-toggle status --json    # structured view for monitoring
./adobe-toggle discovery        # dump discovered components (TSV)
./adobe-toggle discovery --json # discovered components as a JSON array
./adobe-toggle summary          # aggregated view (events + state + disabled)
./adobe-toggle summary --json   # same view, structured
./adobe-toggle health           # health probe: exit 0 healthy, 1 unhealthy
./adobe-toggle config show
./adobe-toggle config set tick-interval 60
./adobe-toggle config set safety-tick-interval 300
./adobe-toggle config set notifications off
./adobe-toggle config set auto-start-cc true
./adobe-toggle config set adaptive-interval true  # opt-in: trades drift latency for less CPU (default off)
./adobe-toggle --version
./adobe-toggle --help
```

`--daemon` and `--healthcheck` are invoked by the installed LaunchAgents
and are not meant to be run by hand.

### TUI

```
[a] Allow   [b] Block   [d] Discovery   [s] Stats   [u] Sudo-Sweep   [e] Sudo-Unsweep   [w] Whitelist   [q] Exit
```

- `[b]` Block / `[a]` Allow flip the global state. When there is system-scope
  work that needs elevation, the matching sudo sweep (after Block) or un-sweep
  (after Allow) runs automatically right after the toggle — a single Touch ID
  prompt, and only when something actually needs it. Turn this off with
  `config set auto-sudo-sweep false`.
- `[d]` Discovery shows every Adobe component the daemon currently sees.
- `[u]` Sudo-Sweep manually (re-)runs the system-scope LaunchDaemon sweep —
  the fallback when auto-sweep is disabled, or to run it again (authenticated
  with Touch ID — see Troubleshooting).
- `[e]` Sudo-Unsweep manually re-enables those system-scope LaunchDaemons
  (also Touch ID-authenticated).
- `[w]` Whitelist opens an `fzf` multi-select picker. TAB selects, ENTER
  toggles the selection between whitelisted (always allowed) and
  auto-blocked. Whitelisted components are never blocked, even when the
  global state is `block`. Requires `fzf`.

<!-- Screenshot placeholder: add assets/tui-screenshot.png and uncomment.
![Adobe Toggle Manager TUI](assets/tui-screenshot.png)
-->

### JSON output

Three subcommands accept `--json` for structured output with no external
dependencies:

```bash
$ ./adobe-toggle status --json
{"label":"com.user.adobe-toggle.daemon","state":"block","daemon":{"pid":49033,"ticks":1234,"heartbeat_age_s":42,"tick_interval_s":30,"safety_tick_interval_s":300,"healthy":true,"healthy_reason":"ok"},"backends":{"available":true}}
```

A daemon is `healthy` when its PID is alive **and** its heartbeat age is
under twice the safety-tick interval. When unhealthy, `healthy_reason`
gives the cause (`no-pid`, `pid-not-alive`, `no-heartbeat`,
`heartbeat-stale`).

## Uninstall

```bash
./uninstall.sh
```

The uninstaller:

1. Re-enables every Adobe component it had disabled (Adobe is fully
   restored), then
2. removes both LaunchAgents — the daemon job
   (`com.user.adobe-toggle.daemon`) and the healthcheck job
   (`com.user.adobe-toggle.healthcheck`) — and the runtime files.

Preview exactly what it would do, without changing anything:

```bash
ATM_UNINSTALL_DRY_RUN=1 ./uninstall.sh
```

Other environment toggles:

- `ATM_UNINSTALL_FORCE=1` — skip confirmation prompts.
- `ATM_UNINSTALL_SKIP_RELEASE=1` — remove the tool **without** re-enabling
  Adobe first.
- `ATM_UNINSTALL_BACKUP_LOGS=yes|no|<path>` — control whether logs are
  backed up before removal.

## Troubleshooting

- **Touch ID prompt during a Sudo-Sweep.** System-scope Adobe
  LaunchDaemons live under `/Library/LaunchDaemons` and require elevation.
  The TUI `[u]` Sudo-Sweep authenticates with Touch ID (via `pam_tid.so`)
  rather than asking for a password. Approve the Touch ID prompt to let the
  sweep disable system-scope components. The background daemon skips these
  and logs them; nothing else needs elevation.
- **macOS notification permission prompt.** On first run the tool may ask
  for permission to post notifications. Allow it for block/allow feedback,
  or turn notifications off entirely:
  `./adobe-toggle config set notifications off`.
- **Where are the logs?** Structured NDJSON logs live in
  `~/Library/Application Support/AdobeToggleManager/logs`. Tail the daemon
  log or pipe it through `jq` to debug discovery and block actions.
- **Drift detection feels slow (~30s).** The FSEvents watcher is not
  running. Install the Xcode Command Line Tools
  (`xcode-select --install`) and re-run the installer to build it; this
  drops latency below one second.
- **The whitelist key does nothing.** Install `fzf` (`brew install fzf`).

## Architecture

| Component                | File / path                                            |
| ------------------------ | ------------------------------------------------------ |
| Core                     | `adobe-toggle`                                    |
| Installer                | `install.sh`                          |
| Uninstaller              | `uninstall.sh`                       |
| Backend: launchd         | `lib/backends/launchd.zsh`                              |
| Backend: pluginkit       | `lib/backends/pluginkit.zsh`                            |
| Backend interface spec   | `lib/backends/_interface.zsh`                           |
| FSEvents helper (source) | `swift/atm-watcher.swift`                               |
| Whitelist manager        | `lib/whitelist.zsh`                                     |
| JSON encoder             | `lib/json.zsh`                                          |
| Tests                    | `tests/*.bats`                                          |
| Runtime path             | `~/Library/Application Support/AdobeToggleManager/`     |
| Daemon LaunchAgent       | `~/Library/LaunchAgents/com.user.adobe-toggle.daemon.plist` |
| Healthcheck LaunchAgent  | `~/Library/LaunchAgents/com.user.adobe-toggle.healthcheck.plist` |

New macOS subsystems are added as a zsh file under `lib/backends/` — see
`lib/backends/_interface.zsh` for the backend contract.

## Tests

```bash
brew install bats-core
bats tests/
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full developer workflow.

## Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).
The **public API** — the surface that version numbers make promises about — is:

- the command-line interface: subcommands (`status`, `discovery`, `summary`,
  `health`, `config`) and flags (`--tui`, `--daemon`, `--json`, `--version`);
- the `config` keys and their accepted value domains;
- process **exit codes**;
- the `--json` output schema of `status`, `discovery`, and `summary`.

Internal library modules (`lib/`), log formats, on-disk state files, and TUI key
bindings are **not** part of the public API and may change in any release.

`1.0.0` is the first public release; the tool matured internally through a 4.x
series that was never published (see [CHANGELOG.md](CHANGELOG.md)).

## Security

See [SECURITY.md](SECURITY.md) for the threat model, the deliberate
trade-offs, and how to report a vulnerability.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Adobe Toggle Manager is an independent, unofficial tool. It is **not**
affiliated with, endorsed by, or sponsored by Adobe Inc. "Adobe",
"Creative Cloud", and related names are trademarks of Adobe Inc., used
here only to describe the components this tool manages. See
[TRADEMARKS.md](TRADEMARKS.md).
