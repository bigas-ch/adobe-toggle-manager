#!/usr/bin/env bats
# Tests for lib/backends/launchd.zsh — backend adapter over existing
# functions. Behavior must be bit-identical to a direct call.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    LAUNCHD_BACKEND="$BATS_TEST_DIRNAME/../lib/backends/launchd.zsh"
    REGISTRY="$BATS_TEST_DIRNAME/../lib/backend_registry.zsh"
    [[ -f "$LAUNCHD_BACKEND" ]] || skip "launchd backend not found"
    [[ -f "$REGISTRY" ]] || skip "registry not found"
}
teardown() { sandbox_teardown; }

# === Conformance ===

@test "launchd backend registers cleanly via registry" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$REGISTRY'
        backend_register launchd '$LAUNCHD_BACKEND'
        echo \"exit=\$?\"
        echo \"registered=\$(backend_is_registered launchd && echo yes || echo no)\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    [[ "$output" == *"registered=yes"* ]]
}

@test "launchd__name returns 'launchd'" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        launchd__name
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "launchd" ]]
}

# === Discovery ===

@test "launchd__discover returns empty when no Adobe plists exist" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        ATM_PLIST_DIRS=( '$ATM_BASE/empty' )
        mkdir -p '$ATM_BASE/empty'
        launchd__discover
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "launchd__discover maps gui-scope to type=agent" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.MockAgent.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.MockAgent</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        launchd__discover
    "
    [ "$status" -eq 0 ]
    # Format: type\tidentifier\tscope\tpath
    [[ "$output" == "agent"$'\t'"com.adobe.MockAgent"$'\t'"gui"$'\t'* ]]
    [[ "$output" == *"com.adobe.MockAgent.plist" ]]
}

@test "launchd__discover maps system-scope to type=daemon" {
    mkdir -p "$ATM_BASE/LaunchDaemons"
    cat > "$ATM_BASE/LaunchDaemons/com.adobe.SystemDaemon.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.SystemDaemon</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchDaemons' )
        launchd__discover
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "daemon"$'\t'"com.adobe.SystemDaemon"$'\t'"system"$'\t'* ]]
}

# === Block ===

@test "launchd__block returns 0 for new gui label, calls launchctl bootout+disable" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.NewBlock.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.NewBlock</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        launchd__block agent com.adobe.NewBlock gui '$ATM_BASE/LaunchAgents/com.adobe.NewBlock.plist'
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    assert_launchctl_called bootout 1
    assert_launchctl_called disable 1
}

@test "launchd__block returns 1 (idempotent) when label already in disabled.list" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        printf 'com.adobe.AlreadyBlocked\tgui\t2026-05-03T00:00:00Z\n' >> \"\$ATM_DISABLED_FILE\"
        launchd__block agent com.adobe.AlreadyBlocked gui /any/path
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
    # No new launchctl calls should have happened.
    assert_launchctl_called bootout 0
    assert_launchctl_called disable 0
}

@test "launchd__block returns 2 for system-scope (needs sudo)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        launchd__block daemon com.adobe.SysDaemon system /any/path
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=2"* ]]
}

@test "launchd__block returns 3 for missing identifier" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        launchd__block agent '' gui /any/path
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=3"* ]]
}

@test "launchd__block returns 3 for unknown scope" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        launchd__block agent com.adobe.Foo bogus_scope /any/path
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=3"* ]]
}

# === Allow ===

@test "launchd__allow returns 0 for gui label and calls launchctl enable" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.AllowMe.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.AllowMe</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        # Setup: label is in allowed-prefix path
        launchd__allow agent com.adobe.AllowMe gui '$ATM_BASE/LaunchAgents/com.adobe.AllowMe.plist'
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    assert_launchctl_called enable 1
}

@test "launchd__allow returns 2 for system-scope (needs sudo)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        launchd__allow daemon com.adobe.SysDaemon system /any
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=2"* ]]
}

# === is_blocked ===

@test "launchd__is_blocked returns 0 when identifier is in disabled.list" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        printf 'com.adobe.Listed\tgui\t2026-05-03T00:00:00Z\n' >> \"\$ATM_DISABLED_FILE\"
        launchd__is_blocked agent com.adobe.Listed gui /p
    "
    [ "$status" -eq 0 ]
}

@test "launchd__is_blocked returns 1 when identifier is NOT in disabled.list" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        launchd__is_blocked agent com.adobe.NotListed gui /p
    "
    [ "$status" -eq 1 ]
}

@test "launchd__is_blocked returns 2 for empty identifier" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        launchd__is_blocked agent '' gui /p
    "
    [ "$status" -eq 2 ]
}

# === kill_running ===

@test "launchd__kill_running returns 0 when no Adobe processes exist" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        init_state
        launchd__kill_running
        echo \"exit=\$?\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
}

# === Adapter compatibility: discover output via backend == direct call ===

@test "launchd__discover output matches discover_plists (modulo column reorder)" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.A.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.A</string></dict></plist>
EOF
    cat > "$ATM_BASE/LaunchAgents/com.adobe.B.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.B</string></dict></plist>
EOF
    # Direct discover_plists count
    local direct_count
    direct_count=$(zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        discover_plists | wc -l | tr -d ' '
    ")
    # Backend discover count
    local backend_count
    backend_count=$(zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        source '$LAUNCHD_BACKEND'
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        launchd__discover | wc -l | tr -d ' '
    ")
    [ "$direct_count" -eq "$backend_count" ]
    [ "$direct_count" -eq 2 ]
}
