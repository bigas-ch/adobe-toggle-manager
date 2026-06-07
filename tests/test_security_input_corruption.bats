#!/usr/bin/env bats
# Security tests for malformed input corruption (Finding H-1 — TSV-Re-Read-Validation
# in allow_action; defense-in-depth at every read boundary).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "disabled_list_read survives malformed line (missing scope column)" {
    mkdir -p "$ATM_BASE"
    : > "$ATM_BASE/disabled.list"
    chmod 0600 "$ATM_BASE/disabled.list"
    # Inject a line with only label (no tab, no scope)
    printf 'com.adobe.MalformedNoTab\n' >> "$ATM_BASE/disabled.list"
    printf 'com.adobe.OK\tuser\t2026-05-03\n' >> "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; disabled_list_read"
    [ "$status" -eq 0 ]
    # Read should not crash
}

@test "allow_action skips invalid label in disabled.list (does NOT call launchctl)" {
    mkdir -p "$ATM_BASE"
    : > "$ATM_BASE/disabled.list"
    chmod 0600 "$ATM_BASE/disabled.list"
    # Mix of valid + injection-attempt
    printf 'com.adobe.LegitOne\tuser\t2026-05-03\n' >> "$ATM_BASE/disabled.list"
    printf 'com.adobe.foo;rm -rf /\tuser\t2026-05-03\n' >> "$ATM_BASE/disabled.list"
    printf 'com.adobe.LegitTwo\tuser\t2026-05-03\n' >> "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; allow_action"
    [ "$status" -eq 0 ]
    # Only 2 legit labels → 2 enable calls.
    local enable_count
    enable_count=$(count_log_lines launchctl '^enable')
    [ "$enable_count" = "2" ]
}

@test "allow_action skips invalid scope in disabled.list" {
    mkdir -p "$ATM_BASE"
    : > "$ATM_BASE/disabled.list"
    chmod 0600 "$ATM_BASE/disabled.list"
    # Invalid scope: not gui|user|system
    printf 'com.adobe.X\tROGUE_SCOPE\t2026-05-03\n' >> "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; allow_action"
    [ "$status" -eq 0 ]
    # No launchctl enable should be called for invalid scope
    local enable_count
    enable_count=$(count_log_lines launchctl '^enable')
    [ "$enable_count" = "0" ]
}

@test "discover_plists silently skips plist with malformed Label" {
    # Build a plist whose label contains a TAB — would corrupt TSV output
    mkdir -p "$ATM_BASE/plists"
    cat > "$ATM_BASE/plists/com.adobe.Bad.plist" <<'EOF'
<?xml version="1.0"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.adobe.Bad	WITH-TAB</string>
</dict>
</plist>
EOF
    # Also a legit one
    mock_plist_create "$ATM_BASE/plists" "com.adobe.Good"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; ATM_PLIST_DIRS=( '$ATM_BASE/plists' ); discover_plists"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.Good"* ]]
    # The bad one must not appear in TSV output
    [[ "$output" != *"WITH-TAB"* ]]
}

@test "read_state survives binary garbage in state file" {
    mkdir -p "$ATM_BASE"
    /bin/dd if=/dev/urandom of="$ATM_BASE/state" bs=64 count=1 2>/dev/null
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    [ "$status" -eq 0 ]
    # Must fall back to "block"
    [ "$output" = "block" ]
}

@test "read_state survives empty state file (fallback to block)" {
    mkdir -p "$ATM_BASE"
    : > "$ATM_BASE/state"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; read_state"
    [ "$status" -eq 0 ]
    [ "$output" = "block" ]
}
