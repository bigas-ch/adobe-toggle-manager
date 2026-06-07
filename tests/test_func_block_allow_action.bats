#!/usr/bin/env bats
# Functional tests for block_action / allow_action — full call sequences.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    gen_mock_plists() {
        local dir="$1" count="$2"
        mkdir -p "$dir"
        local i
        for ((i=1; i<=count; i++)); do
            cat > "$dir/com.adobe.MockApp${i}.plist" <<EOF
<?xml version="1.0"?>
<plist version="1.0">
<dict><key>Label</key><string>com.adobe.MockApp${i}</string></dict>
</plist>
EOF
        done
    }
}
teardown() { sandbox_teardown; }

@test "block_action calls disable for every Adobe plist (3 mocks)" {
    gen_mock_plists "$ATM_BASE/LaunchAgents" 3
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    assert_launchctl_called bootout 3
    assert_launchctl_called disable 3
}

@test "block_action is IDEMPOTENT — second call does NOT call launchctl again (skip in disabled.list)" {
    gen_mock_plists "$ATM_BASE/LaunchAgents" 3
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
        block_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # Second call should skip all 3 (already in disabled.list)
    # → still only 3 bootout + 3 disable from first call
    assert_launchctl_called bootout 3
    assert_launchctl_called disable 3
}

@test "block_action then allow_action enables the same labels" {
    gen_mock_plists "$ATM_BASE/LaunchAgents" 2
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
        allow_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # 2 disable from block + 2 enable from allow
    assert_launchctl_called disable 2
    assert_launchctl_called enable 2
}

@test "allow_action clears disabled.list after processing" {
    gen_mock_plists "$ATM_BASE/LaunchAgents" 2
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
        # disabled.list now has 2 entries
        allow_action 2>/dev/null
        # disabled.list now empty
        wc -l < \"\$ATM_DISABLED_FILE\" 2>/dev/null
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"0"* ]]
}

@test "block_action skips system-scope labels (logs WARN_NEEDS_SUDO)" {
    mkdir -p "$ATM_BASE/LaunchDaemons"
    cat > "$ATM_BASE/LaunchDaemons/com.adobe.SystemDaemon.plist" <<EOF
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.SystemDaemon</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchDaemons' )
        init_state
        block_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # No bootout/disable for system-scope
    assert_launchctl_called bootout 0
    assert_launchctl_called disable 0
    # WARN logged
    [ -f "$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).events.ndjson" ]
    grep -q "WARN_NEEDS_SUDO" "$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).events.ndjson"
}

@test "LOG-1 FIXED (v4.1.1): system-scope label in disabled.list does NOT re-emit WARN_NEEDS_SUDO per tick" {
    # Live-system finding 2026-05-03: 1565 WARN_NEEDS_SUDO lines in 1 day for
    # 4 system-scope labels that had already been disabled via the sudo sweep.
    # Idempotency check missing in the system path of disable_launchd_label.
    mkdir -p "$ATM_BASE/LaunchDaemons"
    cat > "$ATM_BASE/LaunchDaemons/com.adobe.SystemDaemon.plist" <<EOF
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.SystemDaemon</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchDaemons' )
        init_state
        # Tick 1: produces the initial WARN_NEEDS_SUDO + adds nothing to disabled.list
        block_action 2>/dev/null
        # Simulate on-demand sudo-sweep manually marking it as disabled
        printf 'com.adobe.SystemDaemon\tsystem\t2026-05-03T00:00:00Z\n' >> \"\$ATM_DISABLED_FILE\"
        # Tick 2 + 3: must NOT add new WARN_NEEDS_SUDO entries
        block_action 2>/dev/null
        block_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    local evt="$ATM_BASE/logs/adobe-toggle.$(date +%Y-%m-%d).events.ndjson"
    [ -f "$evt" ]
    # Exactly ONE WARN_NEEDS_SUDO event total (from Tick 1, before disabled.list was populated).
    # v4.12.0+: NDJSON format — match on "event":"WARN_NEEDS_SUDO" + "details":"com.adobe.SystemDaemon"
    local warn_count
    warn_count=$(grep -c '"event":"WARN_NEEDS_SUDO"' "$evt" || echo 0)
    [ "$warn_count" -eq 1 ]
}

@test "drift detection: new plist appearing between ticks IS discovered + disabled" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    # Tick 1: 1 plist
    gen_mock_plists "$ATM_BASE/LaunchAgents" 1
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
        # Now add a 'drift' plist
        cat > '$ATM_BASE/LaunchAgents/com.adobe.NewDrift.plist' <<EOF
<?xml version=\"1.0\"?>
<plist version=\"1.0\"><dict><key>Label</key><string>com.adobe.NewDrift</string></dict></plist>
EOF
        # Tick 2 — must catch the new plist
        block_action 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # 2 bootout: 1 from tick-1 + 1 from tick-2 (new drift, the original was idempotent-skip)
    assert_launchctl_called bootout 2
}
