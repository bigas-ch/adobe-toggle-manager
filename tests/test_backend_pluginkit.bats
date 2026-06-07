#!/usr/bin/env bats
# Tests for lib/backends/pluginkit.zsh — backend interface implementation
# for macOS pluginkit extensions (FinderSync, ContextMenu, QuickLook).

load helpers/sandbox.bash

setup() {
    sandbox_setup
    PLUGINKIT_BACKEND="$BATS_TEST_DIRNAME/../lib/backends/pluginkit.zsh"
    REGISTRY="$BATS_TEST_DIRNAME/../lib/backend_registry.zsh"
    [[ -f "$PLUGINKIT_BACKEND" ]] || skip "pluginkit backend not found"
    [[ -f "$REGISTRY" ]] || skip "registry not found"

    # Convenience: write a typical 4-row Adobe pluginkit DB.
    # 2 enabled (+), 1 ignored (-), 1 default (space).
    write_typical_db() {
        pluginkit_db_set "$(printf '+    com.adobe.accmac.ACCFinderSync(7.8.10.1)\tUUID-A\t2026-04-23 19:38:15 +0000\t/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app/Contents/PlugIns/ACCFinderSync.appex\n+    com.adobe.acc.AdobeContextMenuExtension(7.0.6.10)\tUUID-B\t2026-04-23 19:38:18 +0000\t/Library/Application Support/Adobe/Adobe OS Extension/Creative Cloud.app/Contents/PlugIns/Adobe Context Menu Extension.appex\n-    com.adobe.InDesign.IDQuickLookPreview(21.3.0)\tUUID-C\t2026-04-23 19:38:17 +0000\t/Applications/Adobe InDesign 2026/Adobe InDesign 2026.app/Contents/PlugIns/IDQuickLookPreview.appex\n     com.adobe.InDesign.IDQuickLookPreview(TBC)\tUUID-D\t2026-04-23 19:38:24 +0000\t/Applications/Adobe InDesign 2026 (Beta)/Adobe InDesign 2026 (Beta).app/Contents/PlugIns/IDQuickLookPreview.appex\n')"
    }
}
teardown() { sandbox_teardown; }

# === Conformance ===

@test "pluginkit backend registers cleanly via registry" {
    run zsh -c "
        source '$REGISTRY'
        backend_register pluginkit '$PLUGINKIT_BACKEND'
        echo \"exit=\$?\"
        echo \"registered=\$(backend_is_registered pluginkit && echo yes || echo no)\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    [[ "$output" == *"registered=yes"* ]]
}

@test "pluginkit__name returns 'pluginkit'" {
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__name"
    [ "$status" -eq 0 ]
    [[ "$output" == "pluginkit" ]]
}

# === Discovery ===

@test "pluginkit__discover returns empty when DB has no Adobe entries" {
    pluginkit_db_set "+    com.apple.foo(1.0)	UUID	date	/path/foo.appex"
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__discover"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pluginkit__discover returns 4-col TSV per Adobe item" {
    write_typical_db
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__discover"
    [ "$status" -eq 0 ]
    # 4 Adobe items in the DB
    [ "${#lines[@]}" -eq 4 ]
}

@test "pluginkit__discover output has type=appex and scope=user" {
    write_typical_db
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__discover"
    [ "$status" -eq 0 ]
    # Each line: type\tidentifier\tscope\tpath  → first col 'appex', third col 'user'
    [[ "${lines[0]}" == "appex"$'\t'*$'\t'"user"$'\t'* ]]
    [[ "${lines[1]}" == "appex"$'\t'*$'\t'"user"$'\t'* ]]
}

@test "pluginkit__discover preserves paths with spaces" {
    write_typical_db
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__discover"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/Library/Application Support/Adobe/Adobe OS Extension/Creative Cloud.app/Contents/PlugIns/Adobe Context Menu Extension.appex"* ]]
}

@test "pluginkit__discover strips version suffix from bundle id" {
    pluginkit_db_set "+    com.adobe.test(99.99.99)	UUID	date	/p"
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__discover"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.test"* ]]
    [[ "$output" != *"99.99.99"* ]]
}

# === Block ===

@test "pluginkit__block returns 0 for ENABLED (+) entry, calls -e ignore" {
    write_typical_db
    run zsh -c "
        source '$PLUGINKIT_BACKEND'
        pluginkit__block appex com.adobe.accmac.ACCFinderSync user /p
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    grep -q "ignore -i com.adobe.accmac.ACCFinderSync" "$ATM_MOCK_LOG_DIR/pluginkit.log"
}

@test "pluginkit__block returns 1 (idempotent) for already-IGNORED (-) entry" {
    write_typical_db
    run zsh -c "
        source '$PLUGINKIT_BACKEND'
        pluginkit__block appex com.adobe.InDesign.IDQuickLookPreview user /p
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
    # No -e ignore call should have happened
    ! grep -q "ignore -i com.adobe.InDesign.IDQuickLookPreview" "$ATM_MOCK_LOG_DIR/pluginkit.log"
}

@test "pluginkit__block returns 3 for missing identifier" {
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__block appex '' user /p; echo exit=\$?"
    [[ "$output" == *"exit=3"* ]]
}

# === Allow ===

@test "pluginkit__allow returns 0 for IGNORED (-) entry, calls -e use" {
    write_typical_db
    run zsh -c "
        source '$PLUGINKIT_BACKEND'
        pluginkit__allow appex com.adobe.InDesign.IDQuickLookPreview user /p
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    grep -q "use -i com.adobe.InDesign.IDQuickLookPreview" "$ATM_MOCK_LOG_DIR/pluginkit.log"
}

@test "pluginkit__allow returns 1 (idempotent) for already-ENABLED (+) entry" {
    write_typical_db
    run zsh -c "
        source '$PLUGINKIT_BACKEND'
        pluginkit__allow appex com.adobe.accmac.ACCFinderSync user /p
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
}

# === is_blocked ===

@test "pluginkit__is_blocked returns 0 for IGNORED (-) entry" {
    write_typical_db
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__is_blocked appex com.adobe.InDesign.IDQuickLookPreview user /p"
    [ "$status" -eq 0 ]
}

@test "pluginkit__is_blocked returns 1 for ENABLED (+) entry" {
    write_typical_db
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__is_blocked appex com.adobe.accmac.ACCFinderSync user /p"
    [ "$status" -eq 1 ]
}

@test "pluginkit__is_blocked returns 2 for unknown identifier" {
    write_typical_db
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__is_blocked appex com.nonexistent.foo user /p"
    [ "$status" -eq 2 ]
}

@test "pluginkit__is_blocked returns 2 for empty identifier" {
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__is_blocked appex '' user /p"
    [ "$status" -eq 2 ]
}

# === kill_running (no Adobe processes in test env) ===

@test "pluginkit__kill_running returns 0 with no Adobe processes" {
    run zsh -c "source '$PLUGINKIT_BACKEND'; pluginkit__kill_running; echo exit=\$?"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
}

# === Hard-Guard ===

@test "_pluginkit__pluginkit hard-guard blocks com.adobe.* on real bin" {
    run zsh -c "
        ATM_PLUGINKIT_BIN=/usr/bin/pluginkit
        ATM_PLUGINKIT_REAL_DENY=1
        source '$PLUGINKIT_BACKEND'
        _pluginkit__pluginkit -e ignore -i com.adobe.evil
    "
    [ "$status" -eq 99 ]
}

# === Multi-Backend Integration: launchd + pluginkit parallel ===

@test "registry can hold launchd + pluginkit and discover from both" {
    LAUNCHD="$BATS_TEST_DIRNAME/../lib/backends/launchd.zsh"
    [[ -f "$LAUNCHD" ]] || skip "launchd backend not found"
    write_typical_db
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.LA.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.LA</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$REGISTRY'
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        backend_register launchd '$LAUNCHD' >/dev/null
        backend_register pluginkit '$PLUGINKIT_BACKEND' >/dev/null
        echo \"backends=\$(backend_list | tr '\n' ',')\"
        backend_discover_all
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"backends=launchd,pluginkit,"* ]]
    # 1 launchd + 4 pluginkit items
    local lines_count
    lines_count=$(echo "$output" | grep -cE "^(launchd|pluginkit)\s")
    [ "$lines_count" -eq 5 ]
}
