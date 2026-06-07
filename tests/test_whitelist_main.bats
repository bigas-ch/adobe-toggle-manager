#!/usr/bin/env bats
# Smoke tests for whitelist_main + _find_fzf (v4.14.3, hot-fix sequence).
# Prevents regression of the v4.14.2 bug (fzf not found in the hardened PATH).

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISCOVERED_FILE="$ATM_BASE/discovered.list"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
    MOCK_FZF="$BATS_TEST_DIRNAME/helpers/mocks/mock_fzf"
    [ -x "$MOCK_FZF" ]
    export ATM_MOCK_FZF_LOG="$ATM_BASE/mock_fzf.log"
}
teardown() { sandbox_teardown; }

# === _find_fzf Tests ===========================================================

@test "_find_fzf: ATM_FZF_BIN override is respected" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='$MOCK_FZF' _find_fzf
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"mock_fzf"* ]]
}

@test "_find_fzf: ATM_FZF_BIN without -x → fallback to standard paths" {
    # Override with a non-existent file
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='/nonexistent/fzf' _find_fzf
    "
    # Should find a real fzf path OR fail (depending on whether the system has fzf)
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    [[ "$output" != *"/nonexistent"* ]]
}

@test "_find_fzf: without ATM_FZF_BIN searches /opt/homebrew, /usr/local, ~/.local" {
    # Verify the hardcoded paths in the function (statically via grep)
    /usr/bin/grep -q "/opt/homebrew/bin/fzf" lib/whitelist.zsh
    /usr/bin/grep -q "/usr/local/bin/fzf" lib/whitelist.zsh
    /usr/bin/grep -q "HOME/.local/bin/fzf" lib/whitelist.zsh
}

# === whitelist_main smoke tests ===============================================

@test "whitelist_main: fail when fzf cannot be found" {
    # Override _find_fzf inline so the 'fzf missing' case can be tested in isolation.
    # The ATM_FZF_BIN override alone is not enough: with a non-existent path
    # _find_fzf falls back to the hardcoded Brew paths and finds the system fzf.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _find_fzf() { return 1; }
        whitelist_main
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"fzf is not installed"* ]]
}

@test "whitelist_main: fail when discovered.list is missing" {
    [ ! -f "$ATM_DISCOVERED_FILE" ]
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='$MOCK_FZF' whitelist_main
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"discovered.list missing"* ]]
}

@test "whitelist_main: empty discovered.list → 'no discovered components'" {
    : > "$ATM_DISCOVERED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='$MOCK_FZF' whitelist_main
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"No discovered"* ]]
}

@test "whitelist_main: ESC cancel is clean (return 0, no state changes)" {
    printf 'launchd\tcom.adobe.test\t/path.plist\tgui\n' > "$ATM_DISCOVERED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='$MOCK_FZF' ATM_MOCK_FZF_CANCEL=1 whitelist_main
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"cancelled"* ]]
    # No state change in disabled.list
    [ ! -f "$ATM_DISABLED_FILE" ] || [ ! -s "$ATM_DISABLED_FILE" ]
}

@test "whitelist_main: select 1 item → state user_allowed in disabled.list" {
    printf 'launchd\tcom.adobe.toggle\t/path.plist\tgui\n' > "$ATM_DISCOVERED_FILE"
    # Mock fzf: simulate selection of the first line (default mode)
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='$MOCK_FZF' whitelist_main
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"toggled"* ]] || [[ "$output" == *"user_allowed"* ]]
    # disabled.list should contain the toggled entry
    [ -f "$ATM_DISABLED_FILE" ]
    /usr/bin/grep -q "com.adobe.toggle.*user_allowed" "$ATM_DISABLED_FILE"
}

@test "whitelist_main: re-toggle of an already-allowed entry → auto_blocked" {
    # Setup: entry already user_allowed
    printf 'launchd\tcom.adobe.toggle\t/path.plist\tgui\n' > "$ATM_DISCOVERED_FILE"
    printf 'com.adobe.toggle\tgui\t2026-05-04T00:00:00Z\tuser_allowed\n' > "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='$MOCK_FZF' whitelist_main
    "
    [ "$status" -eq 0 ]
    # After toggle the state should be auto_blocked
    /usr/bin/grep -q "com.adobe.toggle.*auto_blocked" "$ATM_DISABLED_FILE"
    # No longer user_allowed
    ! /usr/bin/grep -q "com.adobe.toggle.*user_allowed" "$ATM_DISABLED_FILE"
}

@test "whitelist_main: mock_fzf is actually invoked (smoke anti-regression)" {
    printf 'launchd\tcom.adobe.test\t/p.plist\tgui\n' > "$ATM_DISCOVERED_FILE"
    /bin/zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_FZF_BIN='$MOCK_FZF' ATM_MOCK_FZF_LOG='$ATM_MOCK_FZF_LOG' \
            ATM_MOCK_FZF_CANCEL=1 whitelist_main
    " >/dev/null 2>&1
    [ -f "$ATM_MOCK_FZF_LOG" ]
    /usr/bin/grep -q "invoked:" "$ATM_MOCK_FZF_LOG"
    /usr/bin/grep -q "stdin-lines:" "$ATM_MOCK_FZF_LOG"
}
