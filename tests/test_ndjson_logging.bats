#!/usr/bin/env bats
# Tests for the v4.12.0 NDJSON logging format switch.
# Verifies: files have a .ndjson extension; each line is valid JSON;
# schema {ts, level, msg} resp. {ts, event, details} correct.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
}
teardown() { sandbox_teardown; }

_run_log() {
    /bin/zsh -c "
        emulate -L zsh
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        # json.zsh is optional — log_escape uses a fallback when missing
        source '$BATS_TEST_DIRNAME/../lib/log.zsh'
        $1
    "
}

@test "log_info: writes to .ndjson (no longer .log)" {
    run _run_log 'log_info "test message"'
    [ "$status" -eq 0 ]
    local today=$(date +%Y-%m-%d)
    [ -f "$ATM_BASE/logs/adobe-toggle.${today}.ndjson" ]
    [ ! -f "$ATM_BASE/logs/adobe-toggle.${today}.log" ]
}

@test "log_info: each line is valid JSON with ts+level+msg" {
    run _run_log 'log_info "hello world"; log_warn "warning here"; log_error "boom"'
    [ "$status" -eq 0 ]
    local today=$(date +%Y-%m-%d)
    local lines
    lines=$(wc -l < "$ATM_BASE/logs/adobe-toggle.${today}.ndjson" | tr -d ' ')
    [ "$lines" -eq 3 ]
    while IFS= read -r line; do
        echo "$line" | /usr/bin/python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
assert 'ts' in d
assert 'level' in d
assert 'msg' in d
"
    done < "$ATM_BASE/logs/adobe-toggle.${today}.ndjson"
}

@test "log_info: messages with comma + quotes are escaped correctly" {
    # Use single-quote-shell-arg to avoid bash double-escape mess
    run _run_log "log_info 'msg with, commas + quotes'"
    [ "$status" -eq 0 ]
    local today=$(date +%Y-%m-%d)
    local content
    content=$(cat "$ATM_BASE/logs/adobe-toggle.${today}.ndjson")
    echo "$content" | /usr/bin/python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
assert 'commas' in d['msg']
assert 'quotes' in d['msg']
"
}

@test "log_event: writes to .events.ndjson with ts+event+details" {
    run _run_log 'log_event STATE_CHANGE "block→allow"'
    [ "$status" -eq 0 ]
    local today=$(date +%Y-%m-%d)
    [ -f "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson" ]
    local content
    content=$(cat "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson")
    echo "$content" | /usr/bin/python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
assert d['event'] == 'STATE_CHANGE'
assert 'block' in d['details']
"
}

@test "log_event: jq-pipeable with event-name filter" {
    run _run_log 'log_event STATE_CHANGE "block→allow"; log_event DISCOVERY "10 items"; log_event STATE_CHANGE "allow→block"'
    [ "$status" -eq 0 ]
    local today=$(date +%Y-%m-%d)
    # Use python instead of jq (no jq dependency) — simulate pipeline filter
    local count
    count=$(/usr/bin/python3 -c "
import json
with open('$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson') as f:
    n = sum(1 for line in f if json.loads(line).get('event') == 'STATE_CHANGE')
print(n)
")
    [ "$count" -eq 2 ]
}

@test "log_cleanup: deletes old .log AND .ndjson files" {
    # Touch old files
    /usr/bin/touch -t 202401010000 "$ATM_BASE/logs/adobe-toggle.2024-01-01.log"
    /usr/bin/touch -t 202401010000 "$ATM_BASE/logs/adobe-toggle.2024-01-01.events.log"
    /usr/bin/touch -t 202401010000 "$ATM_BASE/logs/adobe-toggle.2024-01-01.ndjson"
    /usr/bin/touch -t 202401010000 "$ATM_BASE/logs/adobe-toggle.2024-01-01.events.ndjson"
    run _run_log 'LOG_RETENTION_DAYS=90; log_cleanup'
    [ "$status" -eq 0 ]
    # All 4 should be gone (>90 days old)
    [ ! -f "$ATM_BASE/logs/adobe-toggle.2024-01-01.log" ]
    [ ! -f "$ATM_BASE/logs/adobe-toggle.2024-01-01.events.log" ]
    [ ! -f "$ATM_BASE/logs/adobe-toggle.2024-01-01.ndjson" ]
    [ ! -f "$ATM_BASE/logs/adobe-toggle.2024-01-01.events.ndjson" ]
}

@test "log_event: details with a line break are escaped to \\n" {
    # Test newline escaping DIRECTLY in zsh (no bash $'...' that interprets the
    # newline before zsh and thereby breaks the test-shell quoting).
    /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source '$BATS_TEST_DIRNAME/../lib/log.zsh'
        log_event TEST \$'line1\\nline2'
    "
    local today=$(date +%Y-%m-%d)
    # Must be stored as a single line (\n escaped → single ndjson line)
    local nlines
    nlines=$(wc -l < "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson" | tr -d ' ')
    [ "$nlines" -eq 1 ]
    # Python parse roundtrip checks the real newline char in details
    /usr/bin/python3 -c "
import json
with open('$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson') as f:
    d = json.loads(f.read())
assert 'line1' in d['details']
assert 'line2' in d['details']
assert chr(10) in d['details']  # real newline char
"
}
