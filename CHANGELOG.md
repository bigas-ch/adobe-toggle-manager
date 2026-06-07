# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See the README's "Versioning" section for the declared public API.

## [Unreleased]

## [1.1.0] - 2026-06-07

### Added
- **Lean** — a third global state (`block` | `lean` | `allow`) that disables
  only curated Adobe *bloat* (CCXProcess, Core Sync, crash/telemetry reporters,
  the ARMDC auto-updater, Adobe Genuine + the GC client, …) while keeping the
  essentials a licensed app needs to launch and stay licensed. Reuses the
  existing per-component whitelist: `user_allowed` components are always spared,
  `user_blocked` ones are always stopped. Surfaced as TUI key `[l]`, daemon
  state `lean`, and `"state":"lean"` in the `--json` output. Conservative by
  design — unknown or new components keep running, so a licensed app never
  breaks. The bloat list (`ATM_BLOAT_PATTERNS` in `lib/bloat.zsh`) is curated
  and may grow in future releases.
- **Classified discovery view** — pressing `[d]` (Discovery) now lists every
  detected Adobe component, grouped into LaunchAgents/Daemons and processes and
  tagged 🅑 bloat / 🅔 essential, instead of only showing a count.
- **Applications launcher** — the installer creates a double-clickable
  `Adobe Toggle.app` in the Applications folder (falls back to `~/Applications`
  when the system folder is not writable) that opens the TUI in Terminal. A
  custom icon is applied when one is present. The uninstaller removes it.

### Changed
- **Non-blocking TUI feedback** — action confirmations no longer freeze the menu
  for ~10 seconds; the status message persists unobtrusively and the next key is
  accepted immediately.

## [1.0.0] - 2026-06-07

First public release. Adobe Toggle Manager matured internally through a 4.x
series (listed below as pre-1.0 history); 1.0.0 is the first public release and
declares a stable public API (CLI subcommands, config keys, exit codes, and the
`--json` output schema — see the README's "Versioning" section).

### Added
- The TUI auto-runs the system-scope `sudo` sweep right after a **Block**, and
  the matching un-sweep right after an **Allow**, so the privileged step no
  longer has to be triggered separately. It only prompts for Touch ID when there
  is actually system-scope work to do, and can be disabled with
  `config set auto-sudo-sweep false`.

### Changed
- `config set tick-interval`/`safety-tick-interval` now reject `0` (a zero
  interval would busy-loop the daemon); values must be a positive integer.

<!-- Pre-1.0 internal history (no public tags exist for these versions). -->

## [4.19.3] - 2026-05-17

### Changed
- Polished the always-on daemon for general macOS use: hardened the
  installer/uninstaller, tightened the daemon loop, and stabilised the test
  suite (600+ bats tests).

### Fixed
- Daemon cleanup-trap scope so signal handlers fire in the caller, not
  inside the function returning.

## [4.16.0] - 2026-05-04

### Added
- Dispatcher-pattern TUI: menu keys resolve to `_tui_action_<key>`
  handlers, keeping each handler small.

### Changed
- Idle-loop fork elimination: the daemon now holds a single sleep child per
  tick instead of one per second, drastically cutting process churn.
- Continued modularisation: the original ~1600-line monolith is now a small
  core plus focused library modules.

## [4.15.0] - 2026-05-04

### Changed
- Hot-path performance: block actions are roughly 7× faster (warm cache)
  via mtime-keyed caches for the disabled list, pluginkit state, plist
  discovery, and code-signing authority, plus zsh builtins (`zstat`,
  `$EPOCHSECONDS`) in place of external `stat`/`date` forks.

## [4.12.0] - 2026-05-03

### Added
- NDJSON structured logging — log lines are `jq`-pipeable.

## [4.11.0] - 2026-05-03

### Added
- Self-healing health probe: a `health` subcommand and a second
  LaunchAgent restart the daemon via `launchctl kickstart` when it is
  unhealthy.

## [4.8.0] - 2026-05-03

### Added
- Granular whitelist: a TUI key opens an `fzf` multi-select picker;
  whitelisted components stay allowed even while the global state is
  `block`. The whitelist persists across reboot.

## [4.7.0] - 2026-05-03

### Added
- JSON output for the `status`, `discovery`, and `summary` subcommands via
  a pure-zsh encoder (no `jq`/`python` runtime dependency).

## [4.5.0] - 2026-05-03

### Added
- FSEvents-driven drift detection: a native Swift helper signals the
  daemon on file events, cutting latency below one second. Falls back to
  30-second polling when the helper is not built.

## [4.4.0] - 2026-05-03

### Changed
- Modularised the monolith into a small core plus library modules.

## [4.3.0] - 2026-05-03

### Added
- Pluggable discovery backends as swappable zsh modules under
  `lib/backends/` (launchd and pluginkit), making new macOS subsystems
  easy to add.

## [4.0.0] - 2026-05-03

### Added
- Security hardening: `0600` state files and `0700` directories
  (`umask 0077`), TOCTOU-resistant code-signing authority cache, strict
  label validation, a fixed `PATH`, Touch ID for the privileged sweep, and
  AppleScript-injection-safe notifications.

## [3.0.0] - 2026-05-02

### Added
- Initial always-on daemon: dynamic Adobe discovery via code-signing
  authority matching, `launchctl disable` blocking, a terminal UI, and
  state that persists across reboot and logout.

[Unreleased]: https://github.com/bigas-ch/adobe-toggle-manager/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/bigas-ch/adobe-toggle-manager/releases/tag/v1.0.0
