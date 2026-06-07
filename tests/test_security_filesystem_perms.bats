#!/usr/bin:env bats
# Security tests for filesystem permissions (Finding C-1 — umask 0077,
# _secure_atm_dirs migration of pre-v4 0644-files to 0600).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# Helper: portable octal-mode read for both BSD-stat and GNU-stat
_mode() {
    /usr/bin/stat -f "%Lp" "$1" 2>/dev/null || /usr/bin/stat -c "%a" "$1" 2>/dev/null
}

@test "init_state creates ATM_BASE with mode 0700" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state"
    [ "$status" -eq 0 ]
    local m=$(_mode "$ATM_BASE")
    [ "$m" = "700" ]
}

@test "init_state creates state file with mode 0600" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state"
    [ "$status" -eq 0 ]
    local m=$(_mode "$ATM_BASE/state")
    [ "$m" = "600" ]
}

@test "write_state preserves 0600 after atomic-write rename" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; write_state allow"
    [ "$status" -eq 0 ]
    local m=$(_mode "$ATM_BASE/state")
    [ "$m" = "600" ]
}

@test "disabled_list_add creates file with mode 0600" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_add com.adobe.X user"
    [ "$status" -eq 0 ]
    local m=$(_mode "$ATM_BASE/disabled.list")
    [ "$m" = "600" ]
}

@test "discovered.list created via discovery_sweep is 0600" {
    # discover_plists with empty ATM_PLIST_DIRS — file still created, just empty
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; ATM_PLIST_DIRS=( '$ATM_BASE/_empty' ); mkdir -p '$ATM_BASE/_empty'; discovery_sweep"
    [ "$status" -eq 0 ]
    [ -f "$ATM_BASE/discovered.list" ]
    local m=$(_mode "$ATM_BASE/discovered.list")
    [ "$m" = "600" ]
}

@test "_secure_atm_dirs MIGRATES pre-existing 0644 file to 0600" {
    # Pre-create files with insecure permissions (simulate pre-v4 install)
    mkdir -p "$ATM_BASE"
    echo "block" > "$ATM_BASE/state"
    chmod 0644 "$ATM_BASE/state"
    chmod 0755 "$ATM_BASE"
    [ "$(_mode "$ATM_BASE/state")" = "644" ]
    [ "$(_mode "$ATM_BASE")" = "755" ]
    # Run migration
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _secure_atm_dirs"
    [ "$status" -eq 0 ]
    [ "$(_mode "$ATM_BASE/state")" = "600" ]
    [ "$(_mode "$ATM_BASE")" = "700" ]
}

@test "_secure_atm_dirs is idempotent (running twice keeps 0600)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _secure_atm_dirs; _secure_atm_dirs"
    [ "$status" -eq 0 ]
    [ "$(_mode "$ATM_BASE/state")" = "600" ]
}

@test "umask 0077 is set during script source (verifies script-level setting)" {
    # Sourcing the script must set umask globally.
    # zsh's umask builtin emits the octal mode WITHOUT leading zero (e.g. "077").
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; umask"
    [ "$status" -eq 0 ]
    [ "$output" = "077" ]
}

@test "logs/-Verzeichnis is 0700 after init" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        # Force log creation so directory exists
        log_info 'test'
    "
    [ "$status" -eq 0 ]
    [ -d "$ATM_BASE/logs" ]
    local m=$(_mode "$ATM_BASE/logs")
    [ "$m" = "700" ]
}

@test "config file (if created) is 0600" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; config_set tick-interval 60"
    [ "$status" -eq 0 ]
    [ -f "$ATM_BASE/config" ]
    local m=$(_mode "$ATM_BASE/config")
    [ "$m" = "600" ]
}

@test "manipulated 0666 state file is reset to 0600 by next init_state call" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state"
    [ "$status" -eq 0 ]
    chmod 0666 "$ATM_BASE/state"
    [ "$(_mode "$ATM_BASE/state")" = "666" ]
    # Second init_state must re-secure
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state"
    [ "$status" -eq 0 ]
    [ "$(_mode "$ATM_BASE/state")" = "600" ]
}
