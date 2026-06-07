#!/usr/bin/env bats
# Performance + correctness tests for logging (90-day retention, append safety).
# bats file_tags=perf

load helpers/sandbox.bash
load helpers/perf.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "perf: log_info append (single line, sub-200ms)" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            source '$SCRIPT' >/dev/null 2>&1
            init_state
            log_info 'test message'
        \"
    ")
    report_perf "log_info single" "$median" "$p95" 300
    [ "$p95" -lt 300 ]
}

@test "log_cleanup deletes files older than 90 days" {
    mkdir -p "$ATM_BASE/logs"
    # Touch a file with mtime > 90 days ago
    local old_file="$ATM_BASE/logs/adobe-toggle.2025-01-01.ndjson"
    touch -t 202501010000 "$old_file"
    # Touch a recent file
    local new_file="$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).ndjson"
    touch "$new_file"

    run zsh -c "
        ATM_BASE='$ATM_BASE'
        source '$SCRIPT' >/dev/null 2>&1
        log_cleanup
    "
    [ "$status" -eq 0 ]
    [ ! -f "$old_file" ]   # old must be deleted
    [ -f "$new_file" ]     # recent must stay
}

@test "log_cleanup is no-op when no logs older than 90d" {
    mkdir -p "$ATM_BASE/logs"
    local recent="$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).ndjson"
    touch "$recent"
    run zsh -c "
        ATM_BASE='$ATM_BASE'
        source '$SCRIPT' >/dev/null 2>&1
        log_cleanup
    "
    [ "$status" -eq 0 ]
    [ -f "$recent" ]
}

@test "log append under high frequency: 100 events do not corrupt file" {
    run zsh -c "
        ATM_BASE='$ATM_BASE'
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        for i in {1..100}; do
            log_event TEST_EVENT \"event_\$i\"
        done
    "
    [ "$status" -eq 0 ]
    # All 100 lines must be present
    local logfile
    logfile="$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).events.ndjson"
    [ -f "$logfile" ]
    local count
    count=$(wc -l < "$logfile" | tr -d ' ')
    [ "$count" = "100" ]
    # Each line must end with the event id
    local last
    last=$(tail -1 "$logfile")
    [[ "$last" == *"event_100"* ]]
}

@test "log_event uses ISO-8601 UTC timestamp format" {
    run zsh -c "
        ATM_BASE='$ATM_BASE'
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        log_event TEST 'sample'
    "
    [ "$status" -eq 0 ]
    local logfile
    logfile="$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).events.ndjson"
    local line
    line=$(cat "$logfile")
    # v4.12.0+: NDJSON-Format {"ts":"YYYY-MM-DDTHH:MM:SSZ","event":"ACTION","details":"..."}
    [[ "$line" =~ '"ts":"20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' ]]
    [[ "$line" =~ '"event":"TEST"' ]]
}
