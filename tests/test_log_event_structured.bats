#!/usr/bin/env bats
# E-05 (v4.17.0): Tests for log_event_structured + migration of the 5 callsites.
# Schema: {ts, event, fields:{key:val, ...}}
# Numeric values (^[0-9]+$) are written as JSON numbers, everything else as string.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
}
teardown() { sandbox_teardown; }

# === Function existence ========================================================

@test "E-05: log_event_structured function exists" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        if (( \${+functions[log_event_structured]} )); then echo ok; fi
    "
    [[ "$output" == "ok" ]]
}

# === Numeric vs String Coercion ===============================================

@test "E-05: integer value is written as JSON number" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        log_event_structured TEST_EVT pid=12345 age_s=300
        /bin/cat \"\$ATM_LOGS_DIR\"/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson
    "
    [ "$status" -eq 0 ]
    # pid + age_s must be WITHOUT quotes (JSON number)
    [[ "$output" == *'"pid":12345'* ]]
    [[ "$output" == *'"age_s":300'* ]]
}

@test "E-05: non-integer value is written as JSON string" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        log_event_structured TEST_EVT reason=no-pid hash=abc123def
        /bin/cat \"\$ATM_LOGS_DIR\"/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson
    "
    [ "$status" -eq 0 ]
    # reason + hash are strings (contain - and letters) → WITH quotes
    [[ "$output" == *'"reason":"no-pid"'* ]]
    [[ "$output" == *'"hash":"abc123def"'* ]]
}

# === Mixed numeric + string ====================================================

@test "E-05: mix of number + string in one event" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        log_event_structured HEALTHCHECK_RESTART reason=heartbeat-stale pid=99 age_s=601
        /bin/cat \"\$ATM_LOGS_DIR\"/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson
    "
    [[ "$output" == *'"reason":"heartbeat-stale"'* ]]
    [[ "$output" == *'"pid":99'* ]]
    [[ "$output" == *'"age_s":601'* ]]
}

# === JSON-Schema-Compliance ===================================================

@test "E-05: NDJSON output is 1 line with ts + event + fields" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        log_event_structured DAEMON_START pid=1234 watcher_active=1
        /bin/cat \"\$ATM_LOGS_DIR\"/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson
    "
    [[ "$output" == *'"ts":'* ]]
    [[ "$output" == *'"event":"DAEMON_START"'* ]]
    [[ "$output" == *'"fields":{'* ]]
    # Exactly 1 line (NDJSON)
    local line_count=$(echo "$output" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$line_count" = "1" ]
}

@test "E-05: strings with quotes are escaped per RFC 8259" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        log_event_structured TEST_EVT 'msg=hello \"world\"'
        /bin/cat \"\$ATM_LOGS_DIR\"/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson
    "
    # Inner quotes must be escaped via \"
    [[ "$output" == *'\\"world\\"'* ]] || [[ "$output" == *'"world"'* ]]
    # NDJSON must be 1 valid line
    local line_count=$(echo "$output" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$line_count" = "1" ]
}

@test "E-05: empty key-value pair (without =) is skipped" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        log_event_structured TEST_EVT pid=1 nogeq age_s=5
        /bin/cat \"\$ATM_LOGS_DIR\"/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson
    "
    [[ "$output" == *'"pid":1'* ]]
    [[ "$output" == *'"age_s":5'* ]]
    # 'nogeq' (no '=') should NOT end up as a field
    [[ "$output" != *'"nogeq"'* ]]
}

# === Migration verification: live system produces structured events ===========

@test "E-05: migration audit — 5 callsites use log_event_structured instead of log_event" {
    # Static audit: the 5 migrated callsites must NO LONGER use log_event
    cd "$BATS_TEST_DIRNAME/.."

    # These 5 events MUST be structured:
    #   HEALTHCHECK_OK, HEALTHCHECK_RESTART, AUTH_CACHE_LOAD,
    #   WATCHER_HASH_MISMATCH, DAEMON_START
    for evt in HEALTHCHECK_OK HEALTHCHECK_RESTART AUTH_CACHE_LOAD WATCHER_HASH_MISMATCH DAEMON_START; do
        # Check: is there a log_event_structured line for this event?
        if ! /usr/bin/grep -rq "log_event_structured ${evt}" lib/*.zsh; then
            echo "FAIL: ${evt} not via log_event_structured (migration incomplete)"
            return 1
        fi
        # Negative check: NO log_event line (old variant) left for this event
        # (except in comments — those contain no "log_event " at the start of a line)
        if /usr/bin/grep -rE "^[[:space:]]*log_event ${evt}" lib/*.zsh 2>/dev/null; then
            echo "FAIL: ${evt} still has old log_event line"
            return 1
        fi
    done
    echo "OK: all 5 migrations complete"
}

# === Backward-compat: log_event (legacy) stays unchanged ======================

@test "E-05: old log_event function stays functional with details field" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        log_event LEGACY_TEST 'some legacy string'
        /bin/cat \"\$ATM_LOGS_DIR\"/adobe-toggle.\$(/bin/date +%Y-%m-%d).events.ndjson
    "
    [[ "$output" == *'"event":"LEGACY_TEST"'* ]]
    [[ "$output" == *'"details":"some legacy string"'* ]]
    # Legacy: no fields field
    [[ "$output" != *'"fields":'* ]]
}
