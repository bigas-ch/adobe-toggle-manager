#!/usr/bin/env bats
# Unit tests for discovery (plist-scan + process detection)

setup() {
    export ATM_BASE="$(mktemp -d)"
    SCRIPT="$BATS_TEST_DIRNAME/../adobe-toggle"
    export FAKE_LD="$(mktemp -d)"
    mkdir -p "$FAKE_LD/Library/LaunchAgents" "$FAKE_LD/Library/LaunchDaemons" "$FAKE_LD/UserLA"
    cat > "$FAKE_LD/Library/LaunchAgents/com.adobe.Test.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.adobe.Test</string>
</dict>
</plist>
EOF
    cat > "$FAKE_LD/Library/LaunchAgents/com.example.Other.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.example.Other</string></dict></plist>
EOF
}

teardown() {
    rm -rf "$ATM_BASE" "$FAKE_LD"
}

@test "discover_plists finds adobe label and ignores non-adobe" {
    run zsh -c "
        ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$FAKE_LD/Library/LaunchAgents' '$FAKE_LD/Library/LaunchDaemons' '$FAKE_LD/UserLA' )
        discover_plists
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.Test"* ]]
    [[ "$output" != *"com.example.Other"* ]]
}

@test "discover_plists assigns 'system' scope for LaunchDaemons" {
    cat > "$FAKE_LD/Library/LaunchDaemons/com.adobe.Daemon.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.Daemon</string></dict></plist>
EOF
    run zsh -c "
        ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$FAKE_LD/Library/LaunchAgents' '$FAKE_LD/Library/LaunchDaemons' '$FAKE_LD/UserLA' )
        discover_plists | grep com.adobe.Daemon
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"system"* ]]
}

@test "discover_plists output is TSV with 4 columns" {
    run zsh -c "
        ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$FAKE_LD/Library/LaunchAgents' '$FAKE_LD/Library/LaunchDaemons' '$FAKE_LD/UserLA' )
        discover_plists | head -1 | awk -F'\t' '{print NF}'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "discover_plists first column is 'launchd'" {
    run zsh -c "
        ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$FAKE_LD/Library/LaunchAgents' '$FAKE_LD/Library/LaunchDaemons' '$FAKE_LD/UserLA' )
        discover_plists | head -1 | awk -F'\t' '{print \$1}'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "launchd" ]
}

@test "discovery_sweep writes to discovered.list" {
    run zsh -c "
        ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$FAKE_LD/Library/LaunchAgents' '$FAKE_LD/Library/LaunchDaemons' '$FAKE_LD/UserLA' )
        discovery_sweep
        cat \"\$ATM_DISCOVERED_FILE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.Test"* ]]
}
