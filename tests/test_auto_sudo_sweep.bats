#!/usr/bin/env bats
# v4.20.0: the TUI auto-chains the system-scope sudo-sweep / sudo-unsweep right
# after a block / allow toggle, gated by config `auto-sudo-sweep` and a non-sudo
# pre-check (so no Touch-ID prompt appears when there is nothing to do).
#
# All paths here are PRE-sudo: we never invoke the real sweep (which needs
# Touch-ID). We test the gating helpers and that _tui_action_b/_tui_action_a
# invoke the chained action only under the right conditions, by stubbing the
# chained _tui_action_u / _tui_action_e to a marker.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

_init() { mkdir -p "$ATM_BASE/logs"; printf 'block\n' > "$ATM_BASE/state"; }

# --- config flag helper ---

@test "_auto_sudo_sweep_enabled: default (no config file) is enabled" {
    _init
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _auto_sudo_sweep_enabled && echo ON || echo OFF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ON"* ]]
}

@test "_auto_sudo_sweep_enabled: config auto-sudo-sweep=false disables" {
    _init
    printf 'auto-sudo-sweep=false\n' > "$ATM_BASE/config"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _auto_sudo_sweep_enabled && echo ON || echo OFF"
    [[ "$output" == *"OFF"* ]]
}

# --- unsweep pre-check ---

@test "_pending_system_unsweep: true with a system non-user_allowed entry" {
    _init
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _pending_system_unsweep && echo YES || echo NO"
    [[ "$output" == *"YES"* ]]
}

@test "_pending_system_unsweep: false when only user_allowed system entries" {
    _init
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tuser_allowed\n' > "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _pending_system_unsweep && echo YES || echo NO"
    [[ "$output" == *"NO"* ]]
}

@test "_pending_system_unsweep: false when disabled.list missing" {
    _init
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _pending_system_unsweep && echo YES || echo NO"
    [[ "$output" == *"NO"* ]]
}

# --- sweep pre-check (discover_plists stubbed) ---

@test "_pending_system_sweep: true when a discovered system label is not yet disabled" {
    _init
    : > "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }; _pending_system_sweep && echo YES || echo NO"
    [[ "$output" == *"YES"* ]]
}

@test "_pending_system_sweep: false when the only system label is already disabled" {
    _init
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }; _pending_system_sweep && echo YES || echo NO"
    [[ "$output" == *"NO"* ]]
}

@test "_pending_system_sweep: false when no system-scope labels are discovered" {
    _init
    : > "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; discover_plists() { printf 'launchd\tcom.adobe.gui\t/x.plist\tgui\n'; }; _pending_system_sweep && echo YES || echo NO"
    [[ "$output" == *"NO"* ]]
}

# --- QW-7: reuse the daemon-maintained discovered.list instead of re-discovering ---
# UX-audit fix: _pending_system_sweep ran discover_plists directly on every [b],
# so a held key fired full live discovery ~3×/sec. It must instead read the
# daemon-maintained discovered.list (via _read_discovered_by_type launchd), with
# a live-discovery fallback only when the file is missing/empty.

@test "_pending_system_sweep: QW-7 reads discovered.list, does NOT call discover_plists" {
    _init
    : > "$ATM_BASE/disabled.list"
    printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n' > "$ATM_BASE/discovered.list"
    # discover_plists is stubbed to emit a benign gui-only line; if the code still
    # re-discovered, the result would be NO. Reading discovered.list yields YES.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; discover_plists() { printf 'launchd\tcom.adobe.gui\t/x.plist\tgui\n'; }; _pending_system_sweep && echo YES || echo NO"
    [[ "$output" == *"YES"* ]]
}

@test "_pending_system_sweep: QW-7 falls back to live discovery when discovered.list missing" {
    _init
    : > "$ATM_BASE/disabled.list"
    [[ -e "$ATM_BASE/discovered.list" ]] && rm -f "$ATM_BASE/discovered.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }; _pending_system_sweep && echo YES || echo NO"
    [[ "$output" == *"YES"* ]]
}

@test "sudo_sweep_action: QW-7 collects labels from discovered.list, not live discovery" {
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_enable    # reach the label-listing; answer 'n' to abort before any sudo
    printf 'launchd\tcom.adobe.fromfile\t/x.plist\tsystem\n' > "$ATM_BASE/discovered.list"
    # If sudo_sweep_action still called discover_plists, the listed label would be
    # com.adobe.fromlive; reading discovered.list lists com.adobe.fromfile.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; discover_plists() { printf 'launchd\tcom.adobe.fromlive\t/x.plist\tsystem\n'; }; print 'n' | sudo_sweep_action"
    [[ "$output" == *"com.adobe.fromfile"* ]]
    [[ "$output" != *"com.adobe.fromlive"* ]]
}

# --- gating inside _tui_action_b (chained sweep stubbed to a marker) ---

@test "_tui_action_b: auto-chains the sweep when enabled and work is pending" {
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_enable   # QW-6: chaining now requires Touch-ID for sudo to be on
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { :; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    [[ "$output" == *"SWEEP_CALLED"* ]]
}

@test "lean (v1.1.0): _tui_action_l does NOT auto-chain the sweep even under block's chaining conditions" {
    # Identical setup to the block auto-chain test above (which DOES sweep) — but
    # lean must never auto-sweep all system LaunchDaemons. Pins the lean-specific
    # no-sweep contract: a copy-paste of block's chain into _tui_action_l fails here.
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_enable
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { :; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_l
    "
    [[ "$output" != *"SWEEP_CALLED"* ]]
}

@test "_tui_action_b: does NOT auto-chain when the flag is disabled" {
    _init
    : > "$ATM_BASE/disabled.list"
    printf 'auto-sudo-sweep=false\n' > "$ATM_BASE/config"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { :; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    [[ "$output" != *"SWEEP_CALLED"* ]]
}

@test "_tui_action_b: does NOT auto-chain when nothing is pending" {
    _init
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { :; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    [[ "$output" != *"SWEEP_CALLED"* ]]
}

# --- gating inside _tui_action_a (chained unsweep stubbed to a marker) ---

@test "_tui_action_a: auto-chains the unsweep when enabled and work is pending" {
    _init
    printf 'allow\n' > "$ATM_BASE/state"
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    pam_tid_enable   # QW-6: chaining now requires Touch-ID for sudo to be on
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { :; }
        _tui_action_e() { echo UNSWEEP_CALLED; }
        _tui_action_a
    "
    [[ "$output" == *"UNSWEEP_CALLED"* ]]
}

@test "_tui_action_a: does NOT auto-chain when there is nothing to re-enable" {
    _init
    printf 'allow\n' > "$ATM_BASE/state"
    : > "$ATM_BASE/disabled.list"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { :; }
        _tui_action_e() { echo UNSWEEP_CALLED; }
        _tui_action_a
    "
    [[ "$output" != *"UNSWEEP_CALLED"* ]]
}

# --- QW-3: chained elevation runs BEFORE the leading ~10 s blink ---
# UX-audit fix: the chained sudo-sweep/unsweep (Touch-ID prompt) must fire
# immediately on keypress, not ~10 s later after _render_with_blink's blocking
# loop. We assert ordering: the chained action's marker precedes the blink's.

@test "_tui_action_b: auto-chained sweep runs BEFORE _render_with_blink" {
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_enable   # QW-6: chaining now requires Touch-ID for sudo to be on
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo BLINK; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    [[ "$output" == *"SWEEP_CALLED"* ]]
    # SWEEP_CALLED must appear before any BLINK line.
    local first
    first=$(printf '%s\n' "$output" | /usr/bin/grep -E 'SWEEP_CALLED|BLINK' | /usr/bin/head -1)
    [[ "$first" == *"SWEEP_CALLED"* ]]
}

@test "_tui_action_b: no leading blink fires when an auto-sweep will follow" {
    # When work is pending, the elevation must not be preceded by a blink at all
    # (so the prompt is instant). Exactly one path may run: chained-first.
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_enable   # QW-6: chaining now requires Touch-ID for sudo to be on
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo BLINK; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    # The blink (if any) must not precede the elevation.
    local first
    first=$(printf '%s\n' "$output" | /usr/bin/grep -E 'SWEEP_CALLED|BLINK' | /usr/bin/head -1)
    [[ "$first" == *"SWEEP_CALLED"* ]]
}

@test "_tui_action_b: still blinks normally when no sweep is chained" {
    _init
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo BLINK; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    [[ "$output" == *"BLINK"* ]]
    [[ "$output" != *"SWEEP_CALLED"* ]]
}

@test "_tui_action_a: auto-chained unsweep runs BEFORE _render_with_blink" {
    _init
    printf 'allow\n' > "$ATM_BASE/state"
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    pam_tid_enable   # QW-6: chaining now requires Touch-ID for sudo to be on
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo BLINK; }
        _tui_action_e() { echo UNSWEEP_CALLED; }
        _tui_action_a
    "
    [[ "$output" == *"UNSWEEP_CALLED"* ]]
    local first
    first=$(printf '%s\n' "$output" | /usr/bin/grep -E 'UNSWEEP_CALLED|BLINK' | /usr/bin/head -1)
    [[ "$first" == *"UNSWEEP_CALLED"* ]]
}

@test "_tui_action_a: still blinks normally when no unsweep is chained" {
    _init
    printf 'allow\n' > "$ATM_BASE/state"
    : > "$ATM_BASE/disabled.list"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo BLINK; }
        _tui_action_e() { echo UNSWEEP_CALLED; }
        _tui_action_a
    "
    [[ "$output" == *"BLINK"* ]]
    [[ "$output" != *"UNSWEEP_CALLED"* ]]
}

# --- QW-6: pending system work + Touch-ID-for-sudo NOT enabled ---
# UX-audit fix: when the auto-chain would fire (work pending) but Touch-ID for
# sudo is OFF, the chained sudo_sweep_action only flashes a "not enabled" snippet
# that the immediate re-render wipes → a first-time user presses [b] and the
# system-scope Adobe daemons keep running, silently. The auto-chain path must
# instead surface a PERSISTENT visible hint (analogous to the pending-[e] hint)
# and NOT call the chained no-op action.

@test "_tui_action_b: pending sweep but Touch-ID OFF → does NOT call _tui_action_u" {
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_disable
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo \"BLINK: \$1\"; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    # The chained no-op action must NOT run when it would only flash + abort.
    [[ "$output" != *"SWEEP_CALLED"* ]]
}

@test "_tui_action_b: pending sweep but Touch-ID OFF → persistent Touch-ID hint" {
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_disable
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo \"BLINK: \$1\"; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    # A visible hint must mention that Touch-ID is required.
    [[ "$output" == *"Touch"* ]]
    # The hint must be persistent: pending_system is recorded so the status box
    # keeps showing the warning line on the next render.
    local pending
    pending=$(zsh -c "source '$SCRIPT' >/dev/null 2>&1; live_state_get pending_system")
    [[ "$pending" == "1" ]]
}

@test "_tui_action_b: pending sweep + Touch-ID ON → still chains the sweep" {
    _init
    : > "$ATM_BASE/disabled.list"
    pam_tid_enable
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        discover_plists() { printf 'launchd\tcom.adobe.sys\t/x.plist\tsystem\n'; }
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo BLINK; }
        _tui_action_u() { echo SWEEP_CALLED; }
        _tui_action_b
    "
    [[ "$output" == *"SWEEP_CALLED"* ]]
}

@test "_tui_action_a: pending unsweep but Touch-ID OFF → does NOT call _tui_action_e" {
    _init
    printf 'allow\n' > "$ATM_BASE/state"
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    pam_tid_disable
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo \"BLINK: \$1\"; }
        _tui_action_e() { echo UNSWEEP_CALLED; }
        _tui_action_a
    "
    [[ "$output" != *"UNSWEEP_CALLED"* ]]
    [[ "$output" == *"Touch"* ]]
}

@test "_tui_action_a: pending unsweep + Touch-ID ON → still chains the unsweep" {
    _init
    printf 'allow\n' > "$ATM_BASE/state"
    printf 'com.adobe.sys\tsystem\t2026-05-07T08:00:00Z\tauto_blocked\n' > "$ATM_BASE/disabled.list"
    pam_tid_enable
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _tui_signal_daemon() { return 1; }
        _render_with_blink() { echo BLINK; }
        _tui_action_e() { echo UNSWEEP_CALLED; }
        _tui_action_a
    "
    [[ "$output" == *"UNSWEEP_CALLED"* ]]
}
