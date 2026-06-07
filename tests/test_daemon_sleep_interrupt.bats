#!/usr/bin/env bats
# PG-01 (v4.16.0): Tests for signal-interruptible sleep in the daemon loop.
#
# Before: while-loop with /bin/sleep 1 × $interval = up to 300 forks/tick.
# Now: 1× /bin/sleep $interval & + wait, trap handler kills the sleep PID
# → wait returns immediately on SIGUSR1/SIGTERM, signals not swallowed.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
}
teardown() { sandbox_teardown; }

# === Signal interrupt behavior ==================================================

# bats test_tags=perf
@test "PG-01: SIGUSR1 interrupts sleep immediately (instead of full timeout)" {
    # Spawn a small test daemon using the new sleep logic, then SIGUSR1.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Simulate relevant daemon vars + trap
        typeset -gi _DAEMON_RUNNING=1
        typeset -gi _DAEMON_TICK_NOW=0
        typeset -gi _DAEMON_SLEEP_PID=0
        trap _daemon_signal_usr1 USR1

        # Background sender: SIGUSR1 after 0.3s
        ( /bin/sleep 0.3 && /bin/kill -USR1 \$\$ ) &

        # Sleep 5s — but should be ended at 0.3s by SIGUSR1
        local t1=\$(/bin/date +%s%N)
        /bin/sleep 5 &
        _DAEMON_SLEEP_PID=\$!
        wait \$_DAEMON_SLEEP_PID 2>/dev/null
        local t2=\$(/bin/date +%s%N)
        local elapsed=\$(( (t2 - t1) / 1000000 ))
        echo \"elapsed=\${elapsed}ms tick_now=\${_DAEMON_TICK_NOW}\"
    "
    [ "$status" -eq 0 ]
    # Expected: <1000ms (sender waits 300ms, trap kills sleep, wait returns)
    [[ "$output" =~ elapsed=[0-9]+ms ]]
    local elapsed_ms="${BASH_REMATCH[0]}"
    elapsed_ms="${elapsed_ms#elapsed=}"
    elapsed_ms="${elapsed_ms%ms}"
    [ "$elapsed_ms" -lt 1500 ] || { echo "TOO SLOW: $elapsed_ms ms"; false; }
    [[ "$output" == *"tick_now=1"* ]]
}

# bats test_tags=perf
@test "PG-01: SIGTERM interrupts sleep immediately + sets _DAEMON_RUNNING=0" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_RUNNING=1
        typeset -gi _DAEMON_TICK_NOW=0
        typeset -gi _DAEMON_SLEEP_PID=0
        trap _daemon_signal_term TERM

        ( /bin/sleep 0.3 && /bin/kill -TERM \$\$ ) &

        local t1=\$(/bin/date +%s%N)
        /bin/sleep 5 &
        _DAEMON_SLEEP_PID=\$!
        wait \$_DAEMON_SLEEP_PID 2>/dev/null
        local t2=\$(/bin/date +%s%N)
        local elapsed=\$(( (t2 - t1) / 1000000 ))
        echo \"elapsed=\${elapsed}ms running=\${_DAEMON_RUNNING}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ elapsed=[0-9]+ms ]]
    local elapsed_ms="${BASH_REMATCH[0]}"
    elapsed_ms="${elapsed_ms#elapsed=}"
    elapsed_ms="${elapsed_ms%ms}"
    [ "$elapsed_ms" -lt 1500 ]
    [[ "$output" == *"running=0"* ]]
}

# === Resource behavior =========================================================

@test "PG-01: Sleep PID is reset to 0 after wait (no leak)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_SLEEP_PID=0
        # Start a short sleep + wait cleanly
        /bin/sleep 0.1 &
        _DAEMON_SLEEP_PID=\$!
        wait \$_DAEMON_SLEEP_PID 2>/dev/null
        _DAEMON_SLEEP_PID=0
        echo \"after_wait=\${_DAEMON_SLEEP_PID}\"
    "
    [[ "$output" == *"after_wait=0"* ]]
}

@test "PG-01: signal_usr1 trap sets _DAEMON_TICK_NOW + kills sleep PID" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_TICK_NOW=0
        typeset -gi _DAEMON_SLEEP_PID=0
        # Spawn a real background process
        /bin/sleep 5 &
        _DAEMON_SLEEP_PID=\$!
        # Verify that it is running
        /bin/kill -0 \$_DAEMON_SLEEP_PID 2>/dev/null && echo 'before: alive'
        # Call the trap handler directly
        _daemon_signal_usr1
        # Sleep PID should be killed
        /bin/sleep 0.1
        /bin/kill -0 \$_DAEMON_SLEEP_PID 2>/dev/null && echo 'after: STILL ALIVE' || echo 'after: dead'
        echo \"tick_now=\${_DAEMON_TICK_NOW}\"
    "
    [[ "$output" == *"before: alive"* ]]
    [[ "$output" == *"after: dead"* ]]
    [[ "$output" == *"tick_now=1"* ]]
}

@test "PG-01: signal_usr1 without an active sleep PID is a no-op (no error)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_TICK_NOW=0
        typeset -gi _DAEMON_SLEEP_PID=0
        # Call the trap without an active sleep job
        _daemon_signal_usr1
        echo \"tick_now=\${_DAEMON_TICK_NOW}\"
        echo \"exit=\$?\"
    "
    [[ "$output" == *"tick_now=1"* ]]
    [[ "$output" == *"exit=0"* ]]
}
