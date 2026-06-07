#!/usr/bin/env bats
# QW-1 (UX-audit Quick-Win): the dead-log bug.
# Before the fix, the three TUI consumers (_recent_drift_events,
# _status_lines_for_box "Last Event", _stats_summary_line) globbed the
# legacy *.events.log (CSV) files and parsed via comma-split. Since v4.12.0
# logging writes ONLY *.events.ndjson → those consumers were permanently
# empty/broken. This test asserts they now surface NDJSON event data.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISCOVERED_FILE="$ATM_BASE/discovered.list"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
}
teardown() { sandbox_teardown; }

# Writes a sample .events.ndjson with one DISABLED drift event for today.
_write_sample_ndjson() {
    local today
    today=$(/bin/date +%Y-%m-%d)
    /bin/cat > "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson" <<'JSON'
{"ts":"2026-06-06T08:15:42Z","event":"DAEMON_START","details":"pid:4242"}
{"ts":"2026-06-06T08:16:10Z","event":"DISABLED","details":"com.adobe.AdobeCreativeCloud:gui"}
JSON
}

# === _events_files: the shared NDJSON glob helper ============================

@test "QW-1: _events_files exists and globs *.events.ndjson" {
    _write_sample_ndjson
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        if (( \${+functions[_events_files]} )); then
            _events_files
        else
            echo MISSING
        fi
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"adobe-toggle."*".events.ndjson"* ]]
    [[ "$output" != *"MISSING"* ]]
}

# === _recent_drift_events: surfaces NDJSON drift events ======================

@test "QW-1: _recent_drift_events surfaces a DISABLED event from .events.ndjson" {
    _write_sample_ndjson
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        _recent_drift_events 5
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISABLED"* ]]
    [[ "$output" == *"com.adobe.AdobeCreativeCloud:gui"* ]]
}

# === _status_lines_for_box: "Last Event" reflects the NDJSON tail ============

@test "QW-1: 'Last Event' line reflects the last .events.ndjson entry" {
    _write_sample_ndjson
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        ATM_DISCOVERED_FILE='$ATM_DISCOVERED_FILE'
        ATM_DISABLED_FILE='$ATM_DISABLED_FILE'
        _status_lines_for_box 58
    "
    [ "$status" -eq 0 ]
    # Must no longer be the empty placeholder
    [[ "$output" != *"Last Event:  —"* ]]
    [[ "$output" == *"Last Event:"*"DISABLED"* ]]
}

# === _stats_summary_line: counts NDJSON events ===============================

@test "QW-1: _stats_summary_line counts events from .events.ndjson" {
    _write_sample_ndjson
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        ATM_DISCOVERED_FILE='$ATM_DISCOVERED_FILE'
        ATM_DISABLED_FILE='$ATM_DISABLED_FILE'
        _stats_summary_line
    "
    [ "$status" -eq 0 ]
    # 2 events in the sample file
    [[ "$output" == *"2 evt today"* ]]
}

# === Activity panel drift section parses NDJSON time + action + details ======

@test "QW-1: _activity_lines_for_box renders parsed NDJSON drift line" {
    _write_sample_ndjson
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        ATM_DISCOVERED_FILE='$ATM_DISCOVERED_FILE'
        ATM_DISABLED_FILE='$ATM_DISABLED_FILE'
        _activity_lines_for_box 58
    "
    [ "$status" -eq 0 ]
    # Time part extracted from the ISO ts (08:16:10) + action + details
    [[ "$output" == *"08:16:10"* ]]
    [[ "$output" == *"DISABLED"* ]]
    [[ "$output" == *"com.adobe.AdobeCreativeCloud:gui"* ]]
}
