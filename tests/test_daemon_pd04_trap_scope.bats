#!/usr/bin/env bats
# PD-04 (v4.19.3): EXIT-trap scope + watcher liveness recovery.
#
# Background: In zsh, `trap '...' EXIT` inside a function is
# function-local (under `emulate -L zsh` with LOCAL_TRAPS enabled) and
# fires on the function return, not on shell exit. v4.19.2 registered the trap
# in `_daemon_setup` → trap fired right after the setup return,
# killed the freshly started watcher (WATCHER_STOP), wrongly logged
# DAEMON_STOP, and _DAEMON_WATCHER_ACTIVE stayed 1 → safety tick (300s)
# instead of normal tick (30s) → heartbeat-stale → healthcheck kickstart bursts.
#
# Fix: trap moved to `daemon_main` + `_daemon_check_watcher_liveness`
# as per-tick defense-in-depth in case the watcher dies post-startup.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
}
teardown() {
    pkill -f "mock_atm_watcher" 2>/dev/null || true
    sandbox_teardown
}

# === Trap scope: _daemon_setup must no longer set any EXIT trap ==============

@test "PD-04: _daemon_setup registers NO daemon-specific traps" {
    # After the v4.19.3 fix, _daemon_setup must no longer install any traps —
    # neither EXIT nor USR1 nor TERM/INT. All three were function-local in zsh
    # and got cleared again on the setup return → bug class.
    # Verification: after the setup return, `trap -p` shows no daemon handlers.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _watcher_start() { _DAEMON_WATCHER_ACTIVE=1; return 0; }
        _watcher_stop() { :; }
        _daemon_setup >/dev/null 2>&1
        # zsh syntax: 'trap' without args shows all active traps
        trap
    "
    [ "$status" -eq 0 ]
    # None of the known daemon handlers may appear here
    [[ "$output" != *"DAEMON_STOP"* ]]
    [[ "$output" != *"_watcher_stop"* ]]
    [[ "$output" != *"_daemon_signal_usr1"* ]]
    [[ "$output" != *"_daemon_signal_term"* ]]
}

@test "PD-04: no phantom DAEMON_STOP in events log after setup-only" {
    # Before the fix: _daemon_setup return → EXIT trap fired → DAEMON_STOP logged.
    # After the fix: events log contains DAEMON_START, but NO DAEMON_STOP.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _watcher_start() { _DAEMON_WATCHER_ACTIVE=1; return 0; }
        _watcher_stop() { log_event WATCHER_STOP \"\$_ATM_WATCHER_PID\"; }
        _daemon_setup >/dev/null 2>&1
        # explicitly not 'exit' — we want to check the events after the setup return
        EVT=\"\$ATM_LOGS_DIR/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson\"
        /bin/cat \"\$EVT\" 2>/dev/null
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"DAEMON_START"* ]]
    # The bug being fixed: NO DAEMON_STOP after setup-only
    [[ "$output" != *"DAEMON_STOP"* ]]
    [[ "$output" != *"WATCHER_STOP"* ]]
}

# === Watcher liveness recovery: _DAEMON_WATCHER_ACTIVE resets on watcher death

@test "PD-04: _daemon_check_watcher_liveness no-op when WATCHER_ACTIVE=0" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=0
        _watcher_running() { return 1; }   # watcher dead, but flag already 0
        _daemon_check_watcher_liveness
        echo \"active=\$_DAEMON_WATCHER_ACTIVE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"active=0"* ]]
}

@test "PD-04: _daemon_check_watcher_liveness keeps WATCHER_ACTIVE=1 when watcher alive" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        _watcher_running() { return 0; }   # watcher alive
        _daemon_check_watcher_liveness
        echo \"active=\$_DAEMON_WATCHER_ACTIVE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"active=1"* ]]
}

@test "PD-04: _daemon_check_watcher_liveness resets WATCHER_ACTIVE to 0 when watcher dead" {
    # Core path: post-startup watcher death is detected + flag reset.
    # Without this reset, the daemon stays on the safety tick (300s) instead of
    # the normal tick (30s) and reports as unhealthy on the healthcheck.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        _watcher_running() { return 1; }   # watcher dead
        _daemon_check_watcher_liveness
        echo \"active=\$_DAEMON_WATCHER_ACTIVE\"
        # log_warn output should contain the fallback message
        EVT=\"\$ATM_LOGS_DIR/adobe-toggle.\$(/bin/date +%Y-%m-%d).ndjson\"
        /bin/cat \"\$EVT\" 2>/dev/null
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"active=0"* ]]
    [[ "$output" == *"watcher died post-startup"* ]]
}

@test "PD-04: _daemon_check_watcher_liveness no-op when _watcher_running missing" {
    # Safety: if lib/watcher.zsh is not loaded (e.g. legacy fallback),
    # the liveness-check function must not crash.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        # unset _watcher_running
        unfunction _watcher_running 2>/dev/null
        _daemon_check_watcher_liveness
        echo \"active=\$_DAEMON_WATCHER_ACTIVE exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"active=1"* ]]
    [[ "$output" == *"exit=0"* ]]
}

# === Daemon lifecycle smoke: trap in daemon_main scope fires on shell exit ====

@test "PD-04: daemon_main installs USR1 + TERM/INT traps in the right scope" {
    # Verifies that after entering daemon_main (before the first tick), USR1 + TERM
    # handlers are set. Without the v4.19.3 fix they were gone after the setup
    # return (function-local) → SIGUSR1 killed the daemon hard instead of triggering
    # a tick, SIGTERM terminated without cleanup.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _watcher_start() { _DAEMON_WATCHER_ACTIVE=1; return 0; }
        _watcher_stop() { :; }
        discovery_sweep() { :; }
        block_action() {
            # Trap state to stdout, then end the loop
            # Note: zsh syntax is 'trap' without args (shows all), not 'trap -p SIG'
            trap
            _DAEMON_RUNNING=0
        }
        notify() { :; }
        print -- 'block' > \"\$ATM_STATE_FILE\"
        typeset -gi _DAEMON_TICK_NOW=1
        daemon_main
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"_daemon_signal_usr1"* ]]
    [[ "$output" == *"_daemon_signal_term"* ]]
}

@test "PD-04: daemon_main EXIT-trap fires once on loop-return (not on setup-return)" {
    # End-to-end smoke: daemon_main with a stubbed block_action that sets
    # _DAEMON_RUNNING=0 after exactly one tick. Loop ends cleanly, daemon_main
    # returns, EXIT trap fires → DAEMON_STOP exactly 1×. Without the v4.19.3 fix
    # it would be 0× (trap was removed from scope on the setup return) or 2×
    # (1× phantom on setup, 1× real on the daemon_main return).
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _watcher_start() { _DAEMON_WATCHER_ACTIVE=1; return 0; }
        _watcher_stop() { log_event WATCHER_STOP test; }
        discovery_sweep() { :; }
        # block_action stub: sets RUNNING=0 → loop ends after 1 tick
        block_action() { _DAEMON_RUNNING=0; }
        allow_action() { :; }
        notify() { :; }
        print -- 'block' > \"\$ATM_STATE_FILE\"
        typeset -gi _DAEMON_TICK_NOW=1   # skips the sleep in the tick
        daemon_main >/dev/null 2>&1 || true
        EVT=\"\$ATM_LOGS_DIR/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson\"
        /usr/bin/grep -c '\"event\":\"DAEMON_STOP\"' \"\$EVT\" 2>/dev/null
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "1" ]]
}
