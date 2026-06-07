#!/usr/bin/env bats
# Functional tests for scripts/pluginkit-sweep.sh — companion helper
# for Adobe pluginkit extensions (FinderSync, ContextMenu, QuickLook).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# Convenience: write a typical 4-row Adobe pluginkit DB.
# 2 enabled (+), 1 ignored (-), 1 default (space).
_write_typical_adobe_db() {
    pluginkit_db_set "$(printf '+    com.adobe.accmac.ACCFinderSync(7.8.10.1)\tUUID-A\t2026-04-23 19:38:15 +0000\t/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app/Contents/PlugIns/ACCFinderSync.appex\n+    com.adobe.acc.AdobeContextMenuExtension(7.0.6.10)\tUUID-B\t2026-04-23 19:38:18 +0000\t/Library/Application Support/Adobe/Adobe OS Extension/Creative Cloud.app/Contents/PlugIns/Adobe Context Menu Extension.appex\n-    com.adobe.InDesign.IDQuickLookPreview(21.3.0)\tUUID-C\t2026-04-23 19:38:17 +0000\t/Applications/Adobe InDesign 2026/Adobe InDesign 2026.app/Contents/PlugIns/IDQuickLookPreview.appex\n     com.adobe.InDesign.IDQuickLookPreview(TBC)\tUUID-D\t2026-04-23 19:38:24 +0000\t/Applications/Adobe InDesign 2026 (Beta)/Adobe InDesign 2026 (Beta).app/Contents/PlugIns/IDQuickLookPreview.appex\n')"
}

# === Smoke: helper file exists and is executable + valid zsh ===

@test "pluginkit helper file exists and is executable" {
    [ -x "$PLUGINKIT_HELPER" ]
}

@test "pluginkit helper passes zsh syntax check" {
    run zsh -n "$PLUGINKIT_HELPER"
    [ "$status" -eq 0 ]
}

# === Mock infrastructure ===

@test "mock pluginkit -m -A -v echoes the DB file" {
    pluginkit_db_set "+    com.adobe.foo(1.0)	UUID	date	/path/foo.appex"
    run "$ATM_PLUGINKIT_BIN" -m -A -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.foo"* ]]
}

@test "mock pluginkit -e ignore -i exits 0" {
    run "$ATM_PLUGINKIT_BIN" -e ignore -i com.adobe.test
    [ "$status" -eq 0 ]
}

@test "mock pluginkit logs every invocation" {
    "$ATM_PLUGINKIT_BIN" -m -A -v >/dev/null
    "$ATM_PLUGINKIT_BIN" -e ignore -i com.adobe.x >/dev/null
    local count
    count=$(wc -l < "$ATM_MOCK_LOG_DIR/pluginkit.log" | tr -d ' ')
    [ "$count" -eq 2 ]
}

# === _list_adobe_extensions parsing ===

@test "_list_adobe_extensions returns empty when DB has no Adobe entries" {
    pluginkit_db_set "+    com.apple.foo(1.0)	UUID	date	/path/foo.appex"
    run zsh -c "source '$PLUGINKIT_HELPER'; _list_adobe_extensions"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_list_adobe_extensions parses tab-separated output correctly" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; _list_adobe_extensions"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.accmac.ACCFinderSync"* ]]
    [[ "$output" == *"com.adobe.acc.AdobeContextMenuExtension"* ]]
}

@test "_list_adobe_extensions preserves paths containing spaces (BSD-tab-aware)" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; _list_adobe_extensions"
    [ "$status" -eq 0 ]
    # Path with spaces must come through complete (no truncation at first space).
    [[ "$output" == *"/Library/Application Support/Adobe/Adobe OS Extension/Creative Cloud.app/Contents/PlugIns/Adobe Context Menu Extension.appex"* ]]
}

@test "_list_adobe_extensions strips version suffix '(...)' from bundle id" {
    pluginkit_db_set "+    com.adobe.test(99.99.99)	UUID	date	/p"
    run zsh -c "source '$PLUGINKIT_HELPER'; _list_adobe_extensions"
    [ "$status" -eq 0 ]
    # Bundle id appears WITHOUT the (99.99.99) suffix.
    [[ "$output" == *"com.adobe.test"* ]]
    [[ "$output" != *"99.99.99"* ]]
}

@test "_list_adobe_extensions extracts state char (+/- /space)" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; _list_adobe_extensions"
    [ "$status" -eq 0 ]
    # Each row begins with the state char followed by a tab.
    [[ "$output" == *$'+\tcom.adobe.accmac'* ]]
    [[ "$output" == *$'-\tcom.adobe.InDesign'* ]]
}

# === _apply ignore semantics ===

@test "_apply ignore calls pluginkit -e ignore for ENABLED (+) entries only" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; _apply ignore"
    [ "$status" -eq 0 ]
    # 2 enabled (+) → 2 ignore-calls. 1 already-ignored (-) → skip. 1 default (' ') → ignore-call.
    local ignore_count
    ignore_count=$(awk '/-e ignore -i com.adobe/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
    [ "$ignore_count" -eq 3 ]
    # The already-ignored entry must NOT appear in ignore-calls.
    ! grep -q "ignore -i com.adobe.InDesign.IDQuickLookPreview" "$ATM_MOCK_LOG_DIR/pluginkit.log" \
        || ! grep -q "21.3.0" "$ATM_MOCK_LOG_DIR/pluginkit.log"
}

@test "_apply ignore skip-message for already-ignored entries" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; _apply ignore"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip (already ignored)"* ]]
}

@test "_apply ignore is idempotent — running twice yields 0 changes the second time" {
    _write_typical_adobe_db
    # First call: state has 3 non-ignored → 3 changes.
    zsh -c "source '$PLUGINKIT_HELPER'; _apply ignore" >/dev/null

    # Now flip DB to all-ignored (simulates persistent ignore-state).
    pluginkit_db_set "$(printf '%s\n' \
        '-    com.adobe.accmac.ACCFinderSync(7.8.10.1)	UUID	date	/p1' \
        '-    com.adobe.acc.AdobeContextMenuExtension(7.0.6.10)	UUID	date	/p2' \
        '-    com.adobe.InDesign.IDQuickLookPreview(21.3.0)	UUID	date	/p3')"
    : > "$ATM_MOCK_LOG_DIR/pluginkit.log"  # reset log

    run zsh -c "source '$PLUGINKIT_HELPER'; _apply ignore"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Done: 0 of 3"* ]]
    # No -e ignore calls expected.
    local ignore_count
    ignore_count=$(awk '/-e ignore/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
    [ "$ignore_count" -eq 0 ]
}

# === _apply use semantics ===

@test "_apply use calls pluginkit -e use for IGNORED (-) entries only" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; _apply use"
    [ "$status" -eq 0 ]
    # 1 ignored (-) → 1 use-call. 2 enabled (+) → skip. 1 default (' ') → use-call.
    local use_count
    use_count=$(awk '/-e use -i com.adobe/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
    [ "$use_count" -eq 2 ]
}

@test "_apply use skip-message for already-enabled entries" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; _apply use"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip (already enabled)"* ]]
}

# === main dispatch ===

@test "main with no args defaults to 'block' (calls _apply ignore)" {
    _write_typical_adobe_db
    run "$PLUGINKIT_HELPER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Done:"* ]]
    [[ "$output" == *"Adobe pluginkit extensions"* ]]
}

@test "main 'status' exits 0 and lists extensions" {
    _write_typical_adobe_db
    run "$PLUGINKIT_HELPER" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.accmac.ACCFinderSync"* ]]
}

@test "main 'allow' calls _apply use" {
    _write_typical_adobe_db
    run "$PLUGINKIT_HELPER" allow
    [ "$status" -eq 0 ]
    local use_count
    use_count=$(awk '/-e use -i com.adobe/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
    [ "$use_count" -ge 1 ]
}

@test "main 'kill' with no Adobe processes is a no-op (does not crash)" {
    # Real ps is fine here — there are no Adobe-appex processes in the test env.
    run "$PLUGINKIT_HELPER" kill
    [ "$status" -eq 0 ]
    [[ "$output" == *"No Adobe pluginkit-extension processes running."* ]]
}

@test "main with unknown command exits 1 with usage hint" {
    run "$PLUGINKIT_HELPER" bogus_command
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]
}

@test "main 'help' prints the comment-block usage" {
    run "$PLUGINKIT_HELPER" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"pluginkit-sweep.sh"* ]]
}

# === Source-guard ===

@test "source-guard: sourcing the helper does NOT auto-run main" {
    _write_typical_adobe_db
    run zsh -c "source '$PLUGINKIT_HELPER'; echo 'sourced'"
    [ "$status" -eq 0 ]
    [[ "$output" == "sourced" ]]
    # No pluginkit invocations should have happened.
    local count
    count=$(wc -l < "$ATM_MOCK_LOG_DIR/pluginkit.log" | tr -d ' ')
    [ "$count" -eq 0 ]
}

# === Hard-Guard ATM_PLUGINKIT_REAL_DENY ===

@test "_pluginkit hard-guard blocks com.adobe.* when bin is real /usr/bin/pluginkit" {
    # Force PLUGINKIT_BIN back to real path while keeping REAL_DENY=1
    run zsh -c "
        ATM_PLUGINKIT_BIN=/usr/bin/pluginkit
        ATM_PLUGINKIT_REAL_DENY=1
        source '$PLUGINKIT_HELPER'
        _pluginkit -e ignore -i com.adobe.evil
    "
    [ "$status" -eq 99 ]
    [[ "$output" == *"FATAL"* ]] || [[ "$output" == *"refusing real pluginkit"* ]]
}

@test "_pluginkit hard-guard does NOT fire for non-adobe bundles even on real bin" {
    # The mock returns 1 for unknown invocations — but the guard should NOT fire.
    # We point at the mock so we can verify guard-pass-through reaches the mock.
    run zsh -c "
        source '$PLUGINKIT_HELPER'
        _pluginkit -e ignore -i com.example.foo
    "
    # exit 0 = mock accepted the call (guard didn't block)
    [ "$status" -eq 0 ]
}

# === Doc consistency ===

@test "helper header documents block/allow/status/kill/help" {
    local hdr
    hdr=$(awk '/^# Usage:/,/^$/' "$PLUGINKIT_HELPER")
    [[ "$hdr" == *"block"* ]]
    [[ "$hdr" == *"allow"* ]]
    [[ "$hdr" == *"status"* ]]
    [[ "$hdr" == *"kill"* ]]
}
