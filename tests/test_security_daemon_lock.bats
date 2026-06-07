#!/usr/bin/env bats
# Security tests for daemon single-instance lock (Finding H-2).
# PID file at $ATM_PID_FILE, kill -0 liveness check, atomic write via mv.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "first _acquire_daemon_lock succeeds and writes PID file" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _acquire_daemon_lock"
    [ "$status" -eq 0 ]
    [ -f "$ATM_BASE/daemon.pid" ]
    local pid=$(cat "$ATM_BASE/daemon.pid")
    [[ "$pid" =~ ^[0-9]+$ ]]
}

@test "second _acquire_daemon_lock with LIVE PID FAILS (single-instance)" {
    # Pre-write a live PID into the lock file (use our own shell PID)
    mkdir -p "$ATM_BASE"
    echo "$$" > "$ATM_BASE/daemon.pid"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _acquire_daemon_lock"
    [ "$status" -ne 0 ]
}

@test "stale PID lock file is overwritten (process gone)" {
    mkdir -p "$ATM_BASE"
    # Use a likely-dead PID (max 4-byte value, very unlikely to be running)
    echo "999999" > "$ATM_BASE/daemon.pid"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _acquire_daemon_lock"
    [ "$status" -eq 0 ]
    # PID file should now contain a valid PID, not 999999
    local newpid=$(cat "$ATM_BASE/daemon.pid")
    [ "$newpid" != "999999" ]
}

@test "_release_daemon_lock removes the PID file when PID matches" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        _acquire_daemon_lock
        _release_daemon_lock
    "
    [ "$status" -eq 0 ]
    [ ! -f "$ATM_BASE/daemon.pid" ]
}

@test "SEC-1 FIXED (v4.1.1): _release_daemon_lock returns 0 when PID does not match (file stays)" {
    # Set PID file to an unrelated PID
    mkdir -p "$ATM_BASE"
    echo "12345" > "$ATM_BASE/daemon.pid"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _release_daemon_lock; print -- \"rc=\$?\""
    [ "$status" -eq 0 ]
    # File must still exist with the foreign PID
    [ -f "$ATM_BASE/daemon.pid" ]
    [ "$(cat "$ATM_BASE/daemon.pid")" = "12345" ]
    # rc=0 (fixed in v4.1.1)
    [[ "$output" == *"rc=0"* ]]
}

@test "garbled PID file (non-numeric) is treated as stale" {
    mkdir -p "$ATM_BASE"
    echo "garbage-not-a-pid" > "$ATM_BASE/daemon.pid"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _acquire_daemon_lock"
    [ "$status" -eq 0 ]
}

@test "PID file is created via atomic write (no .tmp leak)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _acquire_daemon_lock"
    [ "$status" -eq 0 ]
    [ ! -f "$ATM_BASE/daemon.pid.tmp" ]
}
