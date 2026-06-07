#!/usr/bin/env bats
# Smoke test for tests/helpers/sandbox.bash + mocks.
# Verifies the test-isolation infrastructure itself:
#   - sandbox_setup creates a fresh, isolated ATM_BASE
#   - mock_launchctl logs invocations and never touches real launchctl
#   - mock_codesign returns Authority strings from the test DB
#   - the new ENV-Hooks (ATM_LAUNCHCTL_BIN, ATM_CODESIGN_BIN) are honoured
#   - ATM_LAUNCHCTL_REAL_DENY guard blocks com.adobe.* calls when active

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "sandbox creates fresh ATM_BASE per test" {
    [ -n "$ATM_BASE" ]
    [ -d "$ATM_BASE" ]
    [[ "$ATM_BASE" == /tmp/* || "$ATM_BASE" == /var/folders/* ]]
}

@test "sandbox sets all required ENV vars" {
    [ -n "$ATM_LAUNCHCTL_BIN" ]
    [ -n "$ATM_CODESIGN_BIN" ]
    [ -n "$ATM_LAUNCHCTL_REAL_DENY" ]
    [ -x "$ATM_LAUNCHCTL_BIN" ]
    [ -x "$ATM_CODESIGN_BIN" ]
    [ "$ATM_LAUNCHCTL_REAL_DENY" = "1" ]
}

@test "mock_launchctl logs invocations and exits 0" {
    run "$ATM_LAUNCHCTL_BIN" disable gui/501/com.adobe.Test
    [ "$status" -eq 0 ]
    run launchctl_log
    [[ "$output" == *"disable"* ]]
    [[ "$output" == *"com.adobe.Test"* ]]
}

@test "mock_launchctl honours ATM_MOCK_LAUNCHCTL_FAIL" {
    ATM_MOCK_LAUNCHCTL_FAIL=1 run "$ATM_LAUNCHCTL_BIN" disable gui/501/com.adobe.Test
    [ "$status" -eq 1 ]
}

@test "mock_codesign returns Authority from DB" {
    codesign_db_add "/Applications/Adobe/Test.app/Contents/MacOS/Test" "Developer ID Application: Adobe Inc. (JQ525L2MZD)"
    run "$ATM_CODESIGN_BIN" -dvv "/Applications/Adobe/Test.app/Contents/MacOS/Test"
    [ "$status" -eq 0 ]
    [[ "${output}${stderr:-}" == *"Adobe Inc."* ]]
}

@test "mock_codesign exits 1 for unknown binary" {
    run "$ATM_CODESIGN_BIN" -dvv "/nonexistent/Binary"
    [ "$status" -eq 1 ]
}

@test "_launchctl wrapper calls mock not real launchctl" {
    # Source the script — the _launchctl function should now call our mock
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl disable test.label"
    [ "$status" -eq 0 ]
    # Mock should have logged the call
    run launchctl_log
    [[ "$output" == *"disable"* ]]
    [[ "$output" == *"test.label"* ]]
}

@test "ATM_LAUNCHCTL_REAL_DENY blocks com.adobe.* on real launchctl" {
    # Force the script to think it's about to call /bin/launchctl (the default).
    # The guard must block this and return 99.
    sandbox_use_real_launchctl_bin
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl disable gui/501/com.adobe.Reader"
    [ "$status" -eq 99 ]
}

@test "ATM_LAUNCHCTL_REAL_DENY allows non-adobe labels through to real launchctl" {
    # Real launchctl with a non-adobe label should NOT be blocked by the guard.
    # We point at /bin/launchctl with a label launchctl will reject (exit != 99).
    # If the guard fires incorrectly, exit would be 99.
    sandbox_use_real_launchctl_bin
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl print gui/501/some.unknown.label"
    [ "$status" -ne 99 ]
}

@test "discovered.list path lives under sandbox ATM_BASE" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; print -- \"\$ATM_DISCOVERED_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$ATM_BASE"/* ]]
}

@test "mock_plist_create generates valid Adobe plist" {
    mock_plist_create "$ATM_BASE/plists" "com.adobe.Smoke"
    [ -f "$ATM_BASE/plists/com.adobe.Smoke.plist" ]
    grep -q "com.adobe.Smoke" "$ATM_BASE/plists/com.adobe.Smoke.plist"
}
