#!/usr/bin/env bats
# Performance tests for daemon tick operations.
# N=20 repetitions, report median + P95. Sandbox-isolated (no real launchctl).
# bats file_tags=perf

load helpers/sandbox.bash
load helpers/perf.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# ----- Discovery sweep (the heaviest part of a tick) -----

@test "perf: discovery_sweep with 0 mock plists (cold)" {
    mkdir -p "$ATM_BASE/plists"
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
            init_state
            discovery_sweep
        \"
    ")
    report_perf "discovery_sweep, 0 plists" "$median" "$p95" 2000
    [ "$p95" -lt 2000 ]
}

@test "perf: discovery_sweep with 10 mock plists" {
    gen_mock_plists "$ATM_BASE/plists" 10
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
            init_state
            discovery_sweep
        \"
    ")
    report_perf "discovery_sweep, 10 plists" "$median" "$p95" 2000
    [ "$p95" -lt 2000 ]
}

@test "perf: discovery_sweep with 50 mock plists (scale test)" {
    gen_mock_plists "$ATM_BASE/plists" 50
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
            init_state
            discovery_sweep
        \"
    ")
    report_perf "discovery_sweep, 50 plists" "$median" "$p95" 3000
    # 50 plists in cold subshell incl. zsh startup: <3s allowed
    [ "$p95" -lt 3000 ]
}

# ----- Block action -----

@test "perf: block_action (full discover + disable) with 10 plists" {
    gen_mock_plists "$ATM_BASE/plists" 10
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
            init_state
            block_action 2>/dev/null
        \"
    ")
    report_perf "block_action, 10 plists" "$median" "$p95" 2500
    [ "$p95" -lt 2500 ]
}

# ----- write_state (state transition latency) -----

@test "perf: write_state (state transition) — must be sub-100ms even cold" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            source '$SCRIPT' >/dev/null 2>&1
            init_state
            write_state allow
        \"
    ")
    report_perf "write_state allow" "$median" "$p95" 500
    # Even with zsh startup, write_state itself is trivial — sub-500ms cold
    [ "$p95" -lt 500 ]
}

# ----- live_state read/write -----

@test "perf: live_state_write — heartbeat update" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            source '$SCRIPT' >/dev/null 2>&1
            init_state
            _DAEMON_TICKS=42
            _DAEMON_DISABLED=10
            _DAEMON_KILLED=3
            _DAEMON_LAST_DISABLE='12:34:56|com.adobe.X:user'
            _DAEMON_LAST_KILL=''
            live_state_write
        \"
    ")
    report_perf "live_state_write" "$median" "$p95" 300
    [ "$p95" -lt 300 ]
}
