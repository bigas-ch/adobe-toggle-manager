#!/usr/bin/env bats
# Security tests for _validate_plist_path (Finding C-2 — allowlist prefix check
# before launchctl bootstrap). Prevents symlink path-traversal bootstrap.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# ----- positive cases -----

@test "SEC-4 FIXED (v4.1.1): legit /Library/LaunchAgents path accepted (zsh \${path:A} replaces /usr/bin/realpath)" {
    [ -d /Library/LaunchAgents ] || skip "no /Library/LaunchAgents on this system"
    local sample
    sample=$(/bin/ls /Library/LaunchAgents/*.plist 2>/dev/null | head -1)
    [ -n "$sample" ] || skip "no plists in /Library/LaunchAgents"
    SAMPLE="$sample" run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path \"\$SAMPLE\""
    [ "$status" -eq 0 ]
}

@test "SEC-4 FIXED (v4.1.1): legit \$HOME/Library/LaunchAgents path accepted" {
    mkdir -p "$HOME/Library/LaunchAgents"
    local tmpfile="$HOME/Library/LaunchAgents/_atm_test_$$.plist"
    echo "<plist/>" > "$tmpfile"
    TMPFILE="$tmpfile" run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path \"\$TMPFILE\""
    local rc=$status
    rm -f "$tmpfile"
    [ "$rc" -eq 0 ]
}

@test "_validate_plist_path correctly rejects non-existent path (regardless of realpath bug)" {
    # This is the ONE positive test that passes — non-existent path is caught
    # before realpath is even called.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path '/nonexistent.plist' 2>/dev/null"
    [ "$status" -ne 0 ]
}

# ----- negative cases — path-traversal + bogus prefixes -----

@test "plist path: path under /tmp rejected (not in allowlist)" {
    local tmpfile="$ATM_BASE/evil.plist"
    echo "<plist/>" > "$tmpfile"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path '$tmpfile' 2>/dev/null"
    [ "$status" -ne 0 ]
}

@test "plist path: nonexistent path rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path '/nonexistent/path.plist'"
    [ "$status" -ne 0 ]
}

@test "plist path: directory rejected (must be regular file)" {
    mkdir -p "$ATM_BASE/dir.plist"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path '$ATM_BASE/dir.plist' 2>/dev/null"
    [ "$status" -ne 0 ]
}

@test "plist path: symlink to file under /etc/passwd rejected (realpath-check)" {
    mkdir -p "$HOME/Library/LaunchAgents"
    local link="$HOME/Library/LaunchAgents/_atm_traversal_$$.plist"
    ln -sf /etc/passwd "$link" 2>/dev/null
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path '$link' 2>/dev/null"
    rm -f "$link"
    # /etc/passwd is not under any allowed prefix → realpath catches this
    [ "$status" -ne 0 ]
}

@test "plist path: path-traversal ../../../etc rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path '$ATM_BASE/../../../etc/passwd' 2>/dev/null"
    [ "$status" -ne 0 ]
}

@test "plist path: extremely long path (>4 KB) rejected" {
    local long_segment
    long_segment=$(printf 'a%.0s' {1..1024})
    local long_path="/tmp/${long_segment}/${long_segment}/${long_segment}/${long_segment}/x.plist"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_plist_path '$long_path' 2>/dev/null"
    [ "$status" -ne 0 ]
}

@test "enable_launchd_label does NOT bootstrap when plist path validation fails" {
    # plist path under /tmp/.../evil.plist is not in allowlist
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        # Inject a non-existent plist path — bootstrap must be skipped
        enable_launchd_label 'com.adobe.NoBootstrap' user 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # _launchctl enable IS called (always tries enable), but bootstrap must NOT
    # because the plist doesn't exist → _validate_plist_path fails → skip.
    assert_launchctl_called bootstrap 0
    assert_launchctl_called enable 1
}
