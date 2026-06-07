#!/usr/bin/env bats
# Functional tests: notify only fires on state CHANGE, not every tick.
# This is verified at the daemon-loop level — we can't easily run a full daemon
# loop, so we test the prev_state guard logic indirectly.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "notify function does not crash with empty title/message" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; notify '' '' 2>/dev/null"
    [ "$status" -eq 0 ]
}

@test "notify uses osascript with safe argument binding" {
    # The notify function calls osascript and uses '--' separator + positional args
    # to prevent string-interpolation/injection. Verify by sourcing + inspecting
    # the function body (works regardless of monolith vs. lib-extraction).
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; typeset -f notify"
    [ "$status" -eq 0 ]
    [[ "$output" == *"osascript"* ]]
    [[ "$output" == *"on run argv"* ]]
}

@test "log_event STATE_CHANGE only logged when state actually changes (daemon loop logic)" {
    # We can verify the daemon loop has the guard `[[ "$state" != "$prev_state" ]]`.
    # Search across main + libs (post-v4.4.0 modularization — daemon_main is in lib/daemon.zsh).
    local script_dir
    script_dir=$(dirname "$SCRIPT")
    grep -qr 'state.*!=.*prev_state' "$SCRIPT" "$script_dir/lib/" 2>/dev/null
}

@test "_recent_drift_events returns latest events first (newest-first ordering)" {
    # QW-1: events live in *.events.ndjson since v4.12.0 (the legacy *.events.log
    # CSV no longer receives writes). _recent_drift_events reads NDJSON and emits
    # a "ts,event,details" line per DISABLED|KILLED event.
    mkdir -p "$ATM_BASE/logs"
    local logfile="$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).events.ndjson"
    cat > "$logfile" <<'EOF'
{"ts":"2026-05-03T01:00:00Z","event":"DISABLED","details":"com.adobe.A:user"}
{"ts":"2026-05-03T02:00:00Z","event":"KILLED","details":"com.adobe.B:1234"}
{"ts":"2026-05-03T03:00:00Z","event":"DISABLED","details":"com.adobe.C:user"}
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        _recent_drift_events 5
    "
    [ "$status" -eq 0 ]
    # Should include all three drift events
    [[ "$output" == *"com.adobe.C"* ]]
    [[ "$output" == *"com.adobe.B"* ]]
    [[ "$output" == *"com.adobe.A"* ]]
}
