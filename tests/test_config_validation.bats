#!/usr/bin/env bats
# QW-2: config_set known-keys allowlist + value-domain validation.
# Guards against silently-swallowed typos (unknown keys) and out-of-domain
# values. Valid keys: tick-interval, safety-tick-interval, notifications,
# auto-start-cc, auto-sudo-sweep, adaptive-interval.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# --- reject-unknown-key ---------------------------------------------------

@test "config_set rejects an unknown key (typo) with non-zero status" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-intervl 60"
    [ "$status" -ne 0 ]
}

@test "config_set prints the valid-key list when an unknown key is given" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set bogus-key 1 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"tick-interval"* ]]
    [[ "$output" == *"safety-tick-interval"* ]]
    [[ "$output" == *"notifications"* ]]
    [[ "$output" == *"auto-start-cc"* ]]
    [[ "$output" == *"auto-sudo-sweep"* ]]
    [[ "$output" == *"adaptive-interval"* ]]
}

@test "config_set does NOT write an unknown key to the config file" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set typo-key 99 2>/dev/null; true"
    [ "$status" -eq 0 ]
    [[ ! -f "$ATM_BASE/config" ]] || ! grep -q "^typo-key=" "$ATM_BASE/config"
}

# --- reject-bad-value -----------------------------------------------------

@test "config_set rejects a non-numeric interval value" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-interval abc 2>&1"
    [ "$status" -ne 0 ]
}

@test "config_set rejects tick-interval=0 (would busy-loop the daemon)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-interval 0 2>&1"
    [ "$status" -ne 0 ]
}

@test "config_set rejects safety-tick-interval=0 (would busy-loop the daemon)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set safety-tick-interval 0 2>&1"
    [ "$status" -ne 0 ]
}

@test "config_set rejects an out-of-domain notifications value" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set notifications full 2>&1"
    [ "$status" -ne 0 ]
}

@test "config_set rejects a non-boolean value for a boolean key" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set auto-sudo-sweep yes 2>&1"
    [ "$status" -ne 0 ]
}

@test "config_set rejects a non-numeric safety-tick-interval value" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set safety-tick-interval -5 2>&1"
    [ "$status" -ne 0 ]
}

@test "config_set does NOT write a value that fails domain validation" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-interval nope 2>/dev/null; true"
    [ "$status" -eq 0 ]
    [[ ! -f "$ATM_BASE/config" ]] || ! grep -q "^tick-interval=" "$ATM_BASE/config"
}

# --- accept-valid ---------------------------------------------------------

@test "config_set accepts a valid interval and echoes the effective value" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-interval 60"
    [ "$status" -eq 0 ]
    [[ "$output" == *"60"* ]]
    grep -q "^tick-interval=60$" "$ATM_BASE/config"
}

@test "config_set accepts notifications=minimal and notifications=off" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set notifications minimal && config_set notifications off"
    [ "$status" -eq 0 ]
    grep -q "^notifications=off$" "$ATM_BASE/config"
}

@test "config_set accepts boolean true/false for boolean keys" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set auto-start-cc true && config_set auto-sudo-sweep false && config_set adaptive-interval true"
    [ "$status" -eq 0 ]
    grep -q "^auto-start-cc=true$" "$ATM_BASE/config"
    grep -q "^auto-sudo-sweep=false$" "$ATM_BASE/config"
    grep -q "^adaptive-interval=true$" "$ATM_BASE/config"
}
