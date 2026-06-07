# Security Policy

## Supported versions

Only the latest released version receives security fixes. Adobe Toggle
Manager is a single-user macOS tool; please update to the latest release
before reporting an issue.

| Version | Supported |
| ------- | --------- |
| 4.19.x  | Yes       |
| < 4.19  | No        |

## Reporting a vulnerability

Report security issues privately via GitHub's **"Report a vulnerability"**
flow under the repository's **Security** tab (Security Advisories). Please
do **not** open a public issue for a vulnerability.

Include:

- your macOS version,
- the tool version (`./adobe-toggle --version`),
- a description of the issue and how to reproduce it.

You can expect an acknowledgement within a few days.

## Threat model

Adobe Toggle Manager is a **single-user macOS daemon** that manages Adobe
Creative Cloud components.

### In scope (actively defended)

- **Adobe auto-restart drift** — Adobe updates re-enable disabled
  LaunchAgents; the daemon re-blocks on the next tick (FSEvents-driven,
  sub-second latency).
- **Race conditions on the state file** — atomic writes via a temp file
  plus `rename(2)`.
- **Single-instance enforcement** — a PID file with a `kill -0` liveness
  check prevents a second daemon.
- **Filesystem permissions** — `0700` directories and `0600` data files
  (`umask 0077`).
- **TOCTOU on the authority cache** — the cache key is
  inode + size + mtime + TTL, and the code-signing authority is
  re-validated without the cache immediately before any `kill` or
  `bootstrap`.
- **TSV/label injection** — a strict label regex
  (`^[A-Za-z][A-Za-z0-9._-]{0,254}$`) at every `launchctl`/TSV boundary.
- **PATH hijacking** — all system tools are addressed absolutely and
  `PATH` is fixed to `/usr/bin:/bin:/usr/sbin:/sbin`.
- **Plist symlink / path traversal** — plist paths are checked against an
  allow-listed set of prefixes before any `bootstrap`.
- **JSON / log injection** — all strings pass through an RFC 8259 escaper.

### Out of scope (by design)

- **Cross-user attacks** on the same machine — the tool is single-user.
- **Root compromise** — if an attacker has root, blocking Adobe is a
  trivial sub-problem.
- **An already-compromised user account** with full read/write access to
  `$HOME` — see trade-off 1 below.
- **Network attacks** — the tool opens no network sockets.

## Deliberate trade-offs

These are conscious design decisions, not oversights.

### 1. The whitelist can be bypassed by editing the state file directly

The disabled-component list has a per-entry state including `user_allowed`,
which the daemon never blocks. Anyone who can write to that file can mark
every Adobe component `user_allowed`; the daemon will obey while the TUI
still reports `state=block`.

**Why accepted:** the file is `0600` (owner only), so this requires full
user access — and with full user access, Adobe can be re-enabled trivially
anyway (e.g. `launchctl bootout`, or just launching an Adobe app). The
bypass adds no new attack surface; it is a sub-capability of an already
compromised account. An HMAC or sanity check would be over-engineering for
a single-user threat model and would break legitimate recovery and
inspection.

**Mitigation:** periodically inspect the list for `user_allowed` entries;
if in doubt, delete it and restart the daemon — discovery re-blocks
everything with `auto_blocked` as the default.

### 2. The FSEvents watcher uses ~140 MB RSS

The watcher runs as a Swift interpreter process. A compiled binary (~5 MB)
would be ideal, but macOS 14+ library validation kills ad-hoc-signed
binaries in the LaunchAgent context, and an Apple Developer ID signature
costs money and adds friction for an open-source project. The
Apple-signed Swift interpreter is accepted by the LaunchAgent, so that is
what ships.

**Mitigation:** the 30-second polling fallback is built in. On
memory-constrained Macs, remove the Xcode Command Line Tools so the watcher
never starts; the daemon then polls (drift latency rises to ~30 s).

### 3. Long-running tests are skipped by default

The 24-hour memory/FD-leak test and the 1-hour cache-TTL test are skipped
by default: they are impractical locally and expensive on hosted CI
runners. Smoke variants cover short-term behaviour. Run the full set
before a major release:

```bash
ATM_LONGRUN=1 bats tests/test_perf_long_running.bats
```

### 4. Pluginkit state has a 60-second stale window

The daemon caches `pluginkit` output for 60 seconds, so external pluginkit
toggles (System Settings, or a manual `pluginkit -e use` in a terminal) may
not be reflected for up to a minute. Adobe app updates — the main drift
trigger — are still caught immediately by the FSEvents watcher, and the
tool's own whitelist toggles invalidate the cache explicitly.

A push-based watcher is not possible here: macOS SIP/sandbox blocks all
access (even as root) to the LaunchServices store that records this state,
so it cannot be watched from outside.

**Mitigation:** force an immediate refresh by sending `SIGUSR1` to the
daemon, or shorten the cache TTL in `lib/backends/pluginkit.zsh`.
