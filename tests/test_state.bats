#!/usr/bin/env bats
# Unit tests for state I/O (read_state, write_state, init_state)

setup() {
    export ATM_BASE="$(mktemp -d)"
    SCRIPT="$BATS_TEST_DIRNAME/../adobe-toggle"
}

teardown() {
    rm -rf "$ATM_BASE"
}

@test "init_state creates state file with default block" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; cat \"\$ATM_STATE_FILE\""
    [ "$status" -eq 0 ]
    [ "$output" = "block" ]
}

@test "read_state returns block on first read" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "block" ]
}

@test "write_state allow then read_state roundtrip" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; write_state allow; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "allow" ]
}

@test "write_state rejects invalid value" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; write_state bogus"
    [ "$status" -ne 0 ]
}

@test "read_state on corrupt file returns block fallback" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; print -n -- 'corrupt' > \"\$ATM_STATE_FILE\"; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "block" ]
}

@test "init_state is idempotent — does not overwrite existing state" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; write_state allow; init_state; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "allow" ]
}

@test "atomic write — no .tmp left behind on success" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; write_state allow; ls \"\$ATM_BASE\"/state.tmp 2>/dev/null; true"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
