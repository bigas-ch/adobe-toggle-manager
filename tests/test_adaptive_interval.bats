#!/usr/bin/env bats
# E-06 (v4.18.0): Tests for the adaptive-tick-interval state machine.
#
# Algorithm recap:
#   - Default: fixed interval (300s safety-tick / 30s tick)
#   - If config adaptive-interval=true AND watcher active:
#     per DEFAULT_ADAPTIVE_QUIET_THRESHOLD (5) quiet ticks → base * 2^N
#     hard-cap at DEFAULT_ADAPTIVE_MAX_INTERVAL (3600s)
#   - Drift detect (disabled delta > 0 OR TICK_NOW=1) → counter=0

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
}
teardown() { sandbox_teardown; }

# === Default behavior (adaptive disabled = legacy) ============================

@test "E-06: without adaptive-interval config the interval stays fixed (300s base)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        typeset -gi _DAEMON_QUIET_TICKS=20  # would normally be many doublings
        # config NOT set → default off → fixed
        config_set safety-tick-interval 300 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "300" ]]
}

@test "E-06: with adaptive=true but no watcher the interval stays fixed" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=0
        typeset -gi _DAEMON_QUIET_TICKS=20
        config_set adaptive-interval true >/dev/null 2>&1
        config_set tick-interval 30 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [ "$status" -eq 0 ]
    # Without watcher: pure polling, no adaptive (otherwise we lose drift triggers)
    [[ "$output" == "30" ]]
}

# === Adaptive mode active: doublings scheme ===================================

@test "E-06: 0 quiet ticks → base interval (300s)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        typeset -gi _DAEMON_QUIET_TICKS=0
        config_set adaptive-interval true >/dev/null 2>&1
        config_set safety-tick-interval 300 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [[ "$output" == "300" ]]
}

@test "E-06: 4 quiet ticks (below threshold 5) → still base interval" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        typeset -gi _DAEMON_QUIET_TICKS=4
        config_set adaptive-interval true >/dev/null 2>&1
        config_set safety-tick-interval 300 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [[ "$output" == "300" ]]
}

@test "E-06: 5 quiet ticks (= 1× threshold) → 2× base = 600s" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        typeset -gi _DAEMON_QUIET_TICKS=5
        config_set adaptive-interval true >/dev/null 2>&1
        config_set safety-tick-interval 300 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [[ "$output" == "600" ]]
}

@test "E-06: 15 quiet ticks (= 3× threshold) → 8× base = 2400s" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        typeset -gi _DAEMON_QUIET_TICKS=15
        config_set adaptive-interval true >/dev/null 2>&1
        config_set safety-tick-interval 300 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [[ "$output" == "2400" ]]
}

@test "E-06: extreme quiet (50 ticks) → cap at MAX 3600s" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        typeset -gi _DAEMON_QUIET_TICKS=50
        config_set adaptive-interval true >/dev/null 2>&1
        config_set safety-tick-interval 300 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    # 50/5 = 10 doublings → 300 * 1024 = 307200, capped at 3600
    [[ "$output" == "3600" ]]
}

# === _daemon_track_drift_for_adaptive state machine ===========================

@test "E-06: track-drift with DISABLED delta > 0 → counter=0 (reset)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_QUIET_TICKS=8
        typeset -gi _DAEMON_DISABLED=10
        typeset -gi _DAEMON_TICK_NOW=0
        # disabled_before = 9 → delta = 1 → reset
        _daemon_track_drift_for_adaptive 9
        echo \"counter=\${_DAEMON_QUIET_TICKS}\"
    "
    [[ "$output" == *"counter=0"* ]]
}

@test "E-06: track-drift with TICK_NOW=1 (FSEvent) → counter=0 (reset)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_QUIET_TICKS=8
        typeset -gi _DAEMON_DISABLED=10
        typeset -gi _DAEMON_TICK_NOW=1
        # disabled delta = 0, but FSEvent → reset
        _daemon_track_drift_for_adaptive 10
        echo \"counter=\${_DAEMON_QUIET_TICKS}\"
    "
    [[ "$output" == *"counter=0"* ]]
}

@test "E-06: track-drift quiet (no delta, no TICK_NOW) → counter+1" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_QUIET_TICKS=3
        typeset -gi _DAEMON_DISABLED=10
        typeset -gi _DAEMON_TICK_NOW=0
        # delta = 0, no FSEvent → increment
        _daemon_track_drift_for_adaptive 10
        echo \"counter=\${_DAEMON_QUIET_TICKS}\"
    "
    [[ "$output" == *"counter=4"* ]]
}

# === Integration verification ================================================

@test "E-06: quiet-ticks counter is initialized to 0 in _daemon_setup" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_QUIET_TICKS=99
        # Stub functions that should do nothing in _daemon_setup
        _acquire_daemon_lock() { return 0; }
        live_state_write() { :; }
        log_cleanup() { :; }
        log_event_structured() { :; }
        _daemon_setup
        echo \"counter=\${_DAEMON_QUIET_TICKS}\"
    "
    [[ "$output" == *"counter=0"* ]]
}

# === Constants check =========================================================

@test "E-06: DEFAULT_ADAPTIVE_QUIET_THRESHOLD = 5" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        echo \"\$DEFAULT_ADAPTIVE_QUIET_THRESHOLD\"
    "
    [[ "$output" == "5" ]]
}

@test "E-06: DEFAULT_ADAPTIVE_MAX_INTERVAL = 3600" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        echo \"\$DEFAULT_ADAPTIVE_MAX_INTERVAL\"
    "
    [[ "$output" == "3600" ]]
}
