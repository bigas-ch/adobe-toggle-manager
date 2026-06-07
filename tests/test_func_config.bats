#!/usr/bin/env bats
# Functional tests for config_get / config_set / config_show.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "config_set writes KEY=VALUE to config file" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-interval 60"
    [ "$status" -eq 0 ]
    [ -f "$ATM_BASE/config" ]
    grep -q "^tick-interval=60$" "$ATM_BASE/config"
}

@test "config_get reads back what config_set wrote (roundtrip)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        config_set tick-interval 45 >/dev/null
        config_get tick-interval
    "
    [ "$status" -eq 0 ]
    [ "$output" = "45" ]
}

@test "config_get returns non-zero for missing key" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        config_get does-not-exist 2>/dev/null
    "
    [ "$status" -ne 0 ]
}

@test "config_set does NOT lose other keys (multi-key support)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        config_set tick-interval 30 >/dev/null
        config_set notifications minimal >/dev/null
        config_get tick-interval
    "
    [ "$status" -eq 0 ]
    [ "$output" = "30" ]
    # Both keys present in file
    grep -q "^tick-interval=30$" "$ATM_BASE/config"
    grep -q "^notifications=minimal$" "$ATM_BASE/config"
}

@test "config_set updates existing key without duplicating it" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        config_set tick-interval 30
        config_set tick-interval 60
        wc -l < \"\$ATM_CONFIG_FILE\"
    "
    [ "$status" -eq 0 ]
    # Should be 1 line (overwritten, not appended)
    [[ "$output" == *"1"* ]]
    grep -q "^tick-interval=60$" "$ATM_BASE/config"
}

@test "config_show lists all keys" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        config_set tick-interval 30
        config_set notifications minimal
        config_show
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"tick-interval"* ]]
    [[ "$output" == *"notifications"* ]]
}

# QW-4 (UX audit): adaptive-interval is read by the daemon and materially
# changes drift latency, but used to be invisible in `config show`.
@test "config_show surfaces adaptive-interval effective value" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        config_show
    "
    [ "$status" -eq 0 ]
    # Default off → shown as 'false (effective)' even without an explicit config entry.
    [[ "$output" == *"adaptive-interval=false (effective)"* ]]
}

@test "config file is mode 0600 after first config_set" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-interval 30"
    [ "$status" -eq 0 ]
    local mode
    mode=$(/usr/bin/stat -f "%Lp" "$ATM_BASE/config")
    [ "$mode" = "600" ]
}
