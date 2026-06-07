#!/usr/bin/env bats
# Functional tests for state lifecycle (block ↔ allow roundtrips, persistence).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "default state on first init is 'block' (User-Anweisung 2026-05-02)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "block" ]
}

@test "ATM_INITIAL_STATE=allow can override default in installer (env contract)" {
    # The installer reads ATM_INITIAL_STATE — the script itself just defaults to block.
    # Verify default is intact when env is unset.
    unset ATM_INITIAL_STATE
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; read_state"
    [ "$output" = "block" ]
}

@test "state persists across multiple source-cycles (file-based)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; write_state allow"
    [ "$status" -eq 0 ]
    # Second source — should read 'allow' from disk
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    [ "$output" = "allow" ]
}

@test "block → allow → block roundtrip preserves state at each step" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        s1=\$(read_state)
        write_state allow
        s2=\$(read_state)
        write_state block
        s3=\$(read_state)
        print \"s1=\$s1 s2=\$s2 s3=\$s3\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"s1=block"* ]]
    [[ "$output" == *"s2=allow"* ]]
    [[ "$output" == *"s3=block"* ]]
}

@test "FINDING SEC-5: concurrent writes race on shared .tmp path (state file falls back to block)" {
    # Two concurrent write_state calls share the same '$ATM_STATE_FILE.tmp' path.
    # One write may fail with 'mv: rename: No such file or directory', but
    # read_state guarantees fallback to 'block' on any corruption — the state
    # file is never left in a torn state.
    # FINDING: tmp path should include $$ or use mktemp to avoid this race.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        write_state allow &
        write_state block &
        wait
        read_state
    " 2>/dev/null   # silence the mv-warning to stderr
    [ "$status" -eq 0 ]
    # The final state value (read_state stdout, last line) must be valid.
    local last
    last=$(echo "$output" | tail -1)
    [ "$last" = "allow" ] || [ "$last" = "block" ]
}

@test "manual mutation of state file to 'corrupt' triggers fallback to block" {
    mkdir -p "$ATM_BASE"
    echo "this-is-not-a-valid-state" > "$ATM_BASE/state"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "block" ]
}

@test "state survives _secure_atm_dirs migration without value loss" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; write_state allow; _secure_atm_dirs; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "allow" ]
}
