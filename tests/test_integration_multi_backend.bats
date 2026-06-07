#!/usr/bin/env bats
# Integration tests: block_action / allow_action use both launchd + pluginkit
# backends (additiv) in a single tick.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "block_action triggers BOTH launchd and pluginkit backends" {
    # Setup: 1 Adobe LaunchAgent + 2 enabled Adobe pluginkit extensions
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.IntegA.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.IntegA</string></dict></plist>
EOF
    pluginkit_db_set "$(printf '+    com.adobe.foo(1.0)\tUUID\tdate\t/p1\n+    com.adobe.bar(1.0)\tUUID\tdate\t/p2\n')"

    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
        echo \"backends_available=\$_BACKENDS_AVAILABLE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"backends_available=1"* ]]
    # launchd: 1 bootout + 1 disable
    assert_launchctl_called bootout 1
    assert_launchctl_called disable 1
    # pluginkit: 2 ignore-calls (for the 2 enabled extensions)
    local ignore_count
    ignore_count=$(awk '/-e ignore -i com.adobe/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
    [ "$ignore_count" -eq 2 ]
}

@test "block_action is idempotent across both backends (second call: 0 new)" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.Idem.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.Idem</string></dict></plist>
EOF
    pluginkit_db_set "$(printf '+    com.adobe.idem1(1.0)\tUUID\tdate\t/p\n')"

    # First call: blocks both
    zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
    " >/dev/null

    # Flip pluginkit DB to ignored to simulate post-block state.
    pluginkit_db_set "$(printf -- '-    com.adobe.idem1(1.0)\tUUID\tdate\t/p\n')"
    : > "$ATM_MOCK_LOG_DIR/launchctl.log"
    : > "$ATM_MOCK_LOG_DIR/pluginkit.log"

    # Second call: should be NO-OP for both backends
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        block_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # No new bootout/disable
    assert_launchctl_called bootout 0
    assert_launchctl_called disable 0
    # No new pluginkit ignore
    local ignore_count
    ignore_count=$(awk '/-e ignore -i com.adobe/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
    [ "$ignore_count" -eq 0 ]
}

@test "allow_action re-enables BOTH launchd and pluginkit blocked items" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.AllowMe.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.AllowMe</string></dict></plist>
EOF
    # Pre-state: 1 launchd-Label in disabled.list + 1 pluginkit ignored
    pluginkit_db_set "$(printf -- '-    com.adobe.iso(1.0)\tUUID\tdate\t/p\n')"

    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        printf 'com.adobe.AllowMe\tgui\t2026-05-03T00:00:00Z\n' >> \"\$ATM_DISABLED_FILE\"
        allow_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # launchd: 1 enable-call
    assert_launchctl_called enable 1
    # pluginkit: 1 use-call
    local use_count
    use_count=$(awk '/-e use -i com.adobe/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
    [ "$use_count" -eq 1 ]
}

@test "block_action works without pluginkit backend (fallback to launchd-only)" {
    # Simulate missing pluginkit backend by unregistering it post-init.
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.OnlyLaunchd.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.OnlyLaunchd</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        backend_unregister pluginkit 2>/dev/null
        block_action 2>/dev/null
        echo \"pluginkit_registered=\$(backend_is_registered pluginkit && echo yes || echo no)\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"pluginkit_registered=no"* ]]
    # launchd still works
    assert_launchctl_called bootout 1
    assert_launchctl_called disable 1
    # Pluginkit was unregistered → no calls (log file may be empty or not exist)
    if [[ -f "$ATM_MOCK_LOG_DIR/pluginkit.log" ]]; then
        local count
        count=$(awk '/-e ignore -i/{n++} END{print n+0}' "$ATM_MOCK_LOG_DIR/pluginkit.log")
        [ "$count" -eq 0 ]
    fi
}
