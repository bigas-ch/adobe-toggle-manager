#!/usr/bin/env bats
# Tests for lib/watcher.zsh — FSEvents watcher lifecycle (v4.5.0).
# Uses mock_atm_watcher (a bash script instead of the Swift binary) so no
# real FSEventStream runs on system paths.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() {
    # Safety net: kill any mock watchers that may still be running
    pkill -f "mock_atm_watcher" 2>/dev/null || true
    sandbox_teardown
}

# === Module-Source ===

@test "lib/watcher.zsh source-able + functions present" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        for fn in _watcher_start _watcher_stop _watcher_running; do
            (( \$+functions[\$fn] )) || { echo MISSING \$fn; exit 1; }
        done
        echo all-present
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"all-present"* ]]
}

# === _watcher_start error paths ===

@test "_watcher_start: invalid daemon-pid returns 3" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        _watcher_start 'not-a-number'
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=3"* ]]
}

@test "_watcher_start: missing binary returns 1 (soft-fallback)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCHER_BIN='/no/such/binary'
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        _watcher_start 12345
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
}

@test "_watcher_start: no existing watch dirs returns 2" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '/no/such/dir1' '/no/such/dir2' )
        _watcher_start 12345
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=2"* ]]
}

@test "_watcher_start: spawn-failure (mock fails) returns 2" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_MOCK_WATCHER_FAIL=1
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        _watcher_start 12345
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=2"* ]]
}

# === _watcher_start happy path ===

@test "_watcher_start: success spawns mock watcher + sets _ATM_WATCHER_PID" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        _watcher_start \$\$
        echo \"exit=\$?\"
        echo \"pid=\$_ATM_WATCHER_PID\"
        # Cleanup
        _watcher_stop
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    [[ "$output" =~ pid=[0-9]+ ]]
    # Verify log entry
    grep -q "invoked:" "$ATM_MOCK_LOG_DIR/atm_watcher.log"
}

@test "_watcher_start: only existing dirs are passed to binary" {
    mkdir -p "$ATM_BASE/dir_a" "$ATM_BASE/dir_b"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '$ATM_BASE/dir_a' '$ATM_BASE/dir_does_not_exist' '$ATM_BASE/dir_b' )
        _watcher_start \$\$
        _watcher_stop
    "
    [ "$status" -eq 0 ]
    # The watcher's log should have only the 2 existing dirs
    [[ "$(cat $ATM_MOCK_LOG_DIR/atm_watcher.log)" == *"$ATM_BASE/dir_a:$ATM_BASE/dir_b"* ]]
}

# === _watcher_stop ===

@test "_watcher_stop: no-op when _ATM_WATCHER_PID=0" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _ATM_WATCHER_PID=0
        _watcher_stop
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
}

@test "_watcher_stop: kills running watcher subprocess" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        _watcher_start \$\$
        local pid=\$_ATM_WATCHER_PID
        _watcher_stop
        # Wait up to 2s for the process to exit
        local i
        for ((i=0; i<10; i++)); do
            kill -0 \$pid 2>/dev/null || break
            sleep 0.2
        done
        kill -0 \$pid 2>/dev/null && echo 'still-alive' || echo 'dead'
        # _ATM_WATCHER_PID should be reset
        echo \"reset=\$_ATM_WATCHER_PID\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"dead"* ]]
    [[ "$output" == *"reset=0"* ]]
}

# === _watcher_running ===

@test "_watcher_running: returns 1 when no PID" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _ATM_WATCHER_PID=0
        _watcher_running
    "
    [ "$status" -eq 1 ]
}

@test "_watcher_running: returns 0 when watcher alive, 1 after stop" {
    # Polling-based instead of a fixed sleep — robust under parallel load
    # (see feedback_ci_polling: macos-14 runners are 3-5x slower than the M3 Max).
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        _watcher_start \$\$
        # Poll until watcher alive OR 5s deadline reached
        local deadline=\$(( SECONDS + 5 ))
        while (( SECONDS < deadline )); do
            _watcher_running && break
            sleep 0.05
        done
        _watcher_running && echo 'alive' || echo 'dead'
        _watcher_stop
        # Poll until watcher dead OR 3s deadline
        deadline=\$(( SECONDS + 3 ))
        while (( SECONDS < deadline )); do
            _watcher_running || break
            sleep 0.05
        done
        _watcher_running && echo 'alive' || echo 'dead'
    "
    [ "$status" -eq 0 ]
    # First check: alive, second check: dead
    [[ "$output" == *"alive"*"dead"* ]]
}

# === USR1-Trigger via mock ===

@test "mock watcher sends SIGUSR1 to daemon-pid after configured delay" {
    # Polling-based: counter sleeps 10s (instead of 4s), watcher fires USR1 after 1s.
    # Test polls until "sent USR1" is in the log or an 8s deadline. Under parallel
    # load the original 4s are too tight (the 1s sleep in the watcher can be
    # delayed by scheduling pressure).
    cat > "$ATM_BASE/usr1_counter.zsh" <<'EOF'
#!/bin/zsh
typeset -gi counter=0
trap 'counter=$(( counter + 1 ))' USR1
trap 'print "USR1 received: $counter"; exit 0' EXIT
sleep 10
EOF
    chmod +x "$ATM_BASE/usr1_counter.zsh"

    "$ATM_BASE/usr1_counter.zsh" &
    local counter_pid=$!
    sleep 0.3

    # Start mock watcher with USR1-trigger after 1s
    ATM_MOCK_WATCHER_USR1_AFTER=1 \
        "$ATM_WATCHER_BIN" "$counter_pid" "$ATM_BASE" &
    local watcher_pid=$!

    # Poll until "sent USR1" is in the log OR 8s deadline
    local deadline=$(( SECONDS + 8 ))
    local result=""
    while (( SECONDS < deadline )); do
        result=$(cat "$ATM_MOCK_LOG_DIR/atm_watcher.log" 2>/dev/null)
        [[ "$result" == *"sent USR1"* ]] && break
        sleep 0.05
    done

    # Cleanup: || true because the process may have already exited
    kill -TERM "$watcher_pid" 2>/dev/null || true
    kill -TERM "$counter_pid" 2>/dev/null || true
    wait 2>/dev/null || true

    # Verify mock log shows USR1-send
    [[ "$result" == *"sent USR1"* ]]
}

# === Daemon-Integration: watcher_active path uses safety-tick-interval ===

@test "daemon spawns watcher when binary available" {
    # Use mock script's run-mode: spawn a daemon for ~1s and check it logged
    # WATCHER_START event before exiting.
    #
    # We can't easily run daemon_main fully (it loops forever), but we can
    # invoke it in a subshell with a timeout that triggers SIGTERM, then
    # check the events log for WATCHER_START.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        # Spawn daemon in background, then SIGTERM after 1s
        ( daemon_main 2>/dev/null ) &
        local dpid=\$!
        sleep 3.0
        kill -TERM \$dpid 2>/dev/null
        wait \$dpid 2>/dev/null
        # Verify WATCHER_START in events log
        grep -q WATCHER_START \"\$ATM_LOGS_DIR/adobe-toggle.\$(date +%Y-%m-%d).events.ndjson\" && echo 'watcher-started' || echo 'no-watcher'
        grep -q DAEMON_START \"\$ATM_LOGS_DIR/adobe-toggle.\$(date +%Y-%m-%d).events.ndjson\" && echo 'daemon-started' || echo 'no-daemon'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"watcher-started"* ]]
    [[ "$output" == *"daemon-started"* ]]
}

@test "daemon falls back to polling when watcher binary missing" {
    # Override ATM_WATCHER_BIN BEFORE source so the typeset-default-init
    # in lib/watcher.zsh picks up the missing-binary value.
    export ATM_WATCHER_BIN='/no/such/binary'
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCH_DIRS=( '$ATM_BASE' )
        ( daemon_main 2>/dev/null ) &
        local dpid=\$!
        sleep 3.0
        kill -TERM \$dpid 2>/dev/null
        wait \$dpid 2>/dev/null
        # WATCHER_START should NOT be in the log
        grep -q WATCHER_START \"\$ATM_LOGS_DIR/adobe-toggle.\$(date +%Y-%m-%d).events.ndjson\" && echo 'watcher-started' || echo 'no-watcher'
        # E-05 (v4.17.0): DAEMON_START now writes fields:{watcher_active:0} (fallback)
        # instead of details:'pid:watcher=0'.
        grep DAEMON_START \"\$ATM_LOGS_DIR/adobe-toggle.\$(date +%Y-%m-%d).events.ndjson\" | tail -1
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-watcher"* ]]
    [[ "$output" == *'"watcher_active":0'* ]]
}
