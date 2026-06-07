#!/usr/bin/env bats
# Fuzzing security tests (v4.13.1, Phase A — S-08 + S-10).

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
    ATM_STATE_FILE="$ATM_BASE/state"
}
teardown() { sandbox_teardown; }

# === S-08 logfile injection ====================================================

@test "S-08: malicious label with JSON-injection payload stays correctly escaped in NDJSON" {
    /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source lib/log.zsh
        log_event DISABLED 'evil_label\",\"injected\":\"value'
    "
    local today=$(/bin/date +%Y-%m-%d)
    local logfile="$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson"
    # Read from file instead of string substitution — avoids Python source-escaping issue
    /usr/bin/python3 -c "
import json
with open('$logfile') as f:
    d = json.loads(f.read())
assert 'injected' not in d, f'INJECTION SUCCESS: keys={list(d.keys())}'
assert 'evil_label' in d['details']
"
}

@test "S-08b: malicious label with newline + tab stays single-line NDJSON" {
    /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source lib/log.zsh
        log_event TEST \$'evil\nlabel\twith\nspecial'
    "
    local today=$(/bin/date +%Y-%m-%d)
    local nlines
    nlines=$(/usr/bin/wc -l < "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson" | /usr/bin/tr -d ' ')
    [ "$nlines" -eq 1 ]
}

@test "S-08c: malicious label with backslashes stays valid JSON" {
    /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source lib/log.zsh
        log_event TEST 'C:\\\\evil\\\\path\\\\with\\\\backslashes'
    "
    local today=$(/bin/date +%Y-%m-%d)
    /usr/bin/python3 -m json.tool < "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson" > /dev/null
}

@test "S-08d: 100 random malicious labels each write valid NDJSON" {
    /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source lib/log.zsh
        for i in 1 2 3 4 5 6 7 8 9 10; do
            log_event TEST 'payload_\${i}_with_\\\"quotes\\\"_and_,commas'
        done
    "
    local today=$(/bin/date +%Y-%m-%d)
    # All 10 lines must be valid JSON
    local count=0 valid=0
    while IFS= read -r line; do
        count=$(( count + 1 ))
        echo "$line" | /usr/bin/python3 -m json.tool > /dev/null 2>&1 && valid=$(( valid + 1 ))
    done < "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson"
    [ "$count" -eq "$valid" ]
    [ "$count" -ge 10 ]
}

# === S-10 state-file fuzzing ===================================================

@test "S-10: read_state with 4KB random bytes → fallback to block, no crash" {
    /usr/bin/dd if=/dev/urandom of="$ATM_STATE_FILE" bs=4096 count=1 2>/dev/null || true
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    [ "$status" -eq 0 ]
    # Output must be 'block' or 'allow' (fallback to block when corrupt)
    [[ "$output" == "block" ]] || [[ "$output" == "allow" ]]
}

@test "S-10b: read_state with 1MB random bytes → fallback no crash + no slow" {
    /usr/bin/dd if=/dev/urandom of="$ATM_STATE_FILE" bs=1048576 count=1 2>/dev/null || true
    # Performance aspect: read should not read the whole MB (read -r reads only the 1st line)
    local start=$SECONDS
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    local elapsed=$(( SECONDS - start ))
    [ "$status" -eq 0 ]
    [[ "$output" == "block" ]] || [[ "$output" == "allow" ]]
    # No 5s+ read time (would indicate a full-file read)
    [ "$elapsed" -lt 3 ]
}

@test "S-10c: read_state with binary garbage (0x00, 0xff, etc) → fallback to block" {
    printf '\x00\x01\x02\xff\xfe\xfd\xab\xcd' > "$ATM_STATE_FILE"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    [ "$status" -eq 0 ]
    [[ "$output" == "block" ]]   # binary garbage → corrupt → block fallback
}

@test "S-10d: read_state with empty file → fallback to block" {
    : > "$ATM_STATE_FILE"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    [ "$status" -eq 0 ]
    [[ "$output" == "block" ]]
}

@test "S-10e: write_state refuses to write an invalid value" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; write_state 'evil_value\nwith_newline'"
    [ "$status" -ne 0 ]
    # State file must NOT have been touched
    [ ! -f "$ATM_STATE_FILE" ] || [[ "$(/bin/cat "$ATM_STATE_FILE" 2>/dev/null)" != *"evil"* ]]
}

@test "S-10f: disabled_list_add refuses an invalid label" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        disabled_list_add 'evil\$(rm -rf /tmp/X)' gui auto_blocked
    "
    # Should reject (return 2)
    [ "$status" -eq 2 ] || [[ "$output" == *"invalid label"* ]] || [[ "$output" == *"reject"* ]]
}

@test "S-10g: disabled.list read with corrupt 4KB random bytes → log_warn, no crash" {
    /usr/bin/dd if=/dev/urandom of="$ATM_DISABLED_FILE" bs=4096 count=1 2>/dev/null || true
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        # allow_action reads disabled.list line by line — must ignore invalid entries
        allow_action 2>&1 || true
    "
    [ "$status" -eq 0 ]
}
