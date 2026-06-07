#!/usr/bin/env bats
# Lean-state (v1.1.0): the global state machine accepts a third value `lean`
# (block | lean | allow). lean blocks only curated Adobe bloat and keeps
# essentials running. This file pins the state-machine contract: write_state
# accepts lean, read_state round-trips it, garbage is still rejected, and a
# corrupt state file still falls back to the safe default (block).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "write_state accepts lean and read_state returns it" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; write_state lean; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "lean" ]
}

@test "write_state still rejects garbage" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; write_state bogus 2>&1"
    [ "$status" -ne 0 ]
}

@test "read_state falls back to block on a corrupt state file" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; print -- 'xxx' > \"\$ATM_STATE_FILE\"; read_state"
    [ "$output" = "block" ]
}
