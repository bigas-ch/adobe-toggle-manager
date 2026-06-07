#!/usr/bin/env bats
# Regression tests for v3.1.x / v3.2.x / v4.x zsh-quirks lessons.
# Each lesson must keep its fix — these tests document the fix.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# v3.2.1 / v3.2.3: 'local var' without value emits 'var=value' on stdout
# when var is already declared in the same function-scope (zsh TTY-only quirk).
@test "REGRESSION v3.2.1: redeclared 'local' must NOT print var=value to stdout" {
    # Smoke check on the gradient_tick function (where the bug originally hit).
    # We verify by sourcing the script and calling _gradient_tick under a wrapper
    # that captures stdout. No 'var=' patterns expected.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Build minimal _RB_BORDER so _gradient_tick doesn't crash
        _RB_BORDER=( '1 1 ─' '1 2 ─' '1 3 ─' '1 4 ─' '1 5 ─' '1 6 ─' )
        _GRADIENT_OFFSET=0
        _GRADIENT_LAST_OFFSET=-1
        _gradient_tick allow 1
    "
    [ "$status" -eq 0 ]
    # No 'var=value' line should appear (would indicate the v3.2.1 bug returned)
    [[ "$output" != *"pos_idx="* ]]
    [[ "$output" != *"k="* ]]
    [[ "$output" != *"cur_state="* ]]
}

# v3.2.4: 'read' without -s echoes characters into TUI
@test "REGRESSION v3.2.4: tui_menu_loop uses read -s (silent) — verify by code grep" {
    # Search across all lib-files + main script (post-v4.4.0 modularization).
    local script_dir
    script_dir=$(dirname "$SCRIPT")
    grep -qrE "read -[sk]|read.*-k.*1" "$SCRIPT" "$script_dir/lib/" 2>/dev/null
}

# Glob with no match under set -u must not crash (NULL_GLOB qualifier)
@test "REGRESSION: glob with NULL_GLOB qualifier (.N) handles empty match" {
    # _secure_atm_dirs uses *(.N) glob — must work with empty dir
    mkdir -p "$ATM_BASE/logs"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _secure_atm_dirs"
    [ "$status" -eq 0 ]
}

# Process-Substitution counter mutation (vs pipe → subshell trap)
@test "REGRESSION v3.1.0 AD-19: counters survive block_action loop (process-sub, not pipe)" {
    mkdir -p "$ATM_BASE/LaunchAgents"
    cat > "$ATM_BASE/LaunchAgents/com.adobe.A.plist" <<EOF
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.A</string></dict></plist>
EOF
    cat > "$ATM_BASE/LaunchAgents/com.adobe.B.plist" <<EOF
<?xml version="1.0"?>
<plist version="1.0"><dict><key>Label</key><string>com.adobe.B</string></dict></plist>
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/LaunchAgents' )
        init_state
        block_action 2>/dev/null
        print -- \"_DAEMON_DISABLED=\$_DAEMON_DISABLED\"
    "
    [ "$status" -eq 0 ]
    # 2 plists → 2 disable actions → counter must reach 2
    [[ "$output" == *"_DAEMON_DISABLED=2"* ]]
}

# v3.1.0 AD-18: disable_launchd_label idempotent
@test "REGRESSION v3.1.0 AD-18: disable_launchd_label is idempotent (skip if already in list)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        disable_launchd_label com.adobe.X user
        disable_launchd_label com.adobe.X user
        disable_launchd_label com.adobe.X user
        wc -l < \"\$ATM_DISABLED_FILE\"
    "
    [ "$status" -eq 0 ]
    # Only 1 entry despite 3 calls
    [[ "$output" == *"1"* ]]
}

# v4.1.0 M-2: codesign cache stays persistent (Out-Vars, no subshell)
@test "REGRESSION v4.1.0 M-2: codesign cache persists across calls in same shell" {
    local bin="$ATM_BASE/Adobe1"
    echo "v1" > "$bin"; chmod +x "$bin"
    codesign_db_add "$bin" "Developer ID Application: Adobe Inc."
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _codesign_auth_and_id '$bin'
        _codesign_auth_and_id '$bin'
        print -- \"size=\${#_AUTHORITY_CACHE[@]}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"size=1"* ]]
}

# v3.1.7: alternative-screen-buffer for clean exit (cant fully test without TTY)
# Just smoke-check that the magic string is present in source
@test "REGRESSION v3.1.7: alternative-screen-buffer escape codes present" {
    # The script uses \033[?1049h (enter alt screen) and \033[?1049l (exit).
    # Grep for the literal string segments without escape complications.
    # Search across main + libs (post-v4.4.0 modularization).
    local script_dir
    script_dir=$(dirname "$SCRIPT")
    grep -qr '1049h' "$SCRIPT" "$script_dir/lib/" 2>/dev/null
    grep -qr '1049l' "$SCRIPT" "$script_dir/lib/" 2>/dev/null
}

# v4.0.0 H-3: PIPE_FAIL set
@test "REGRESSION v4.0.0 H-3: setopt PIPE_FAIL after source" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; setopt | grep -q pipefail && echo YES"
    [ "$status" -eq 0 ]
    [ "$output" = "YES" ]
}

# v4.0.0 C-1: umask 0077 set
@test "REGRESSION v4.0.0 C-1: umask 0077 active after source" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; umask"
    [ "$status" -eq 0 ]
    [ "$output" = "077" ]
}

# v4.1.0 L-2: absolute paths for external commands (no PATH-lookup)
@test "REGRESSION v4.1.0 L-2: critical commands use absolute paths in script" {
    # Verify representative call sites use /bin/ or /usr/bin/ prefixes.
    # Search across main + all libs (post-v4.4.0 modularization).
    local script_dir
    script_dir=$(dirname "$SCRIPT")
    grep -qrE "/bin/(launchctl|date|sleep|cp|mv|rm|mkdir|chmod|cat|kill|ps|ln)|/usr/bin/(awk|grep|sed|stat|head|wc|tr|find|sudo|tail|tput|realpath|libexec/PlistBuddy|pkill)" "$SCRIPT" "$script_dir/lib/" 2>/dev/null
}
