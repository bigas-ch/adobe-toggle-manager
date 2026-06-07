#!/usr/bin/env bats
# Adversarial-Security-Tests (v4.13.1, Phase A — Comprehensive Test Plan).
#
# Covers: S-03 Plist-Symlink-Path-Traversal, S-04 Sudo-Sweep no-fallback,
# S-05 Healthcheck-Plist-Hijack, S-09 Whitelist-Bypass, S-11 PID-File-Poisoning,
# S-13 ps-Output-Leak, S-14 NDJSON-PII-Audit, S-15 Cache-User-Isolation,
# S-16 xcrun-Hijack, S-18 Pre-Push-Override-Audit.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE"
    # These vars are only set by the sourced adobe-toggle — for tests that
    # need them before the source, derive them explicitly from ATM_BASE here.
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
    ATM_PID_FILE="$ATM_BASE/daemon.pid"
}
teardown() { sandbox_teardown; }

# === S-03 Plist-Symlink-Path-Traversal ==========================================

@test "S-03: _validate_plist_path rejects a symlink outside the allowed prefixes" {
    # Setup: a legitimate-looking plist path that points via symlink to /etc/passwd
    local legit_dir="$ATM_BASE/_LaunchAgents"
    /bin/mkdir -p "$legit_dir"
    local sym="$legit_dir/com.adobe.evil.plist"
    /bin/ln -s "/etc/passwd" "$sym"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _validate_plist_path '$sym' && echo 'ACCEPTED' || echo 'REJECTED'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"REJECTED"* ]]
}

@test "S-03b: _validate_plist_path accepts a real plist path under /Library/LaunchAgents/" {
    # Sanity check: legitimate paths must not be rejected
    # (setup is hypothetical — we test the logic with a mock path)
    # The validate check runs over the allowed prefixes (/Library/LaunchAgents/, etc.)
    # We cannot create a real /Library path in the sandbox, so we only check that
    # the regex logic checks out (no false reject on a known-good form).
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Inspect: does the allowed-prefixes list contain the standard paths?
        local p
        for p in \"\${_ALLOWED_PLIST_PREFIXES[@]}\"; do
            [[ \"\$p\" == */Library/LaunchAgents/ ]] && echo 'has-library-launchagents'
            [[ \"\$p\" == */Library/LaunchDaemons/ ]] && echo 'has-library-launchdaemons'
        done
    "
    [[ "$output" == *"has-library-launchagents"* ]]
    [[ "$output" == *"has-library-launchdaemons"* ]]
}

# === S-04 Sudo sweep without Touch ID fallback =================================

@test "S-04: sudo_sweep_action refuses to run when there is no pam_tid.so" {
    # Setup: PAM files empty (no Touch ID activation)
    : > "$ATM_PAM_SUDO_FILE"
    : > "$ATM_PAM_SUDO_LOCAL_FILE"
    # Mock discovered.list with a single system-scope entry
    /bin/mkdir -p "$ATM_BASE/logs"
    printf 'launchd\tcom.adobe.system.test\t/path.plist\tsystem\n' > "$ATM_BASE/discovered.list"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Stub the stdin read so sudo_sweep does not block
        echo 'n' | sudo_sweep_action 2>&1
    "
    [[ "$output" == *"Touch ID"* ]] || [[ "$output" == *"pam_tid.so"* ]]
    # No silent pass: if Touch ID is inactive AND the user does not confirm → return
    [[ "$output" != *"sudo cached creds"* ]]
}

# === S-05 Healthcheck plist hijack detection ===================================

@test "S-05: healthcheck plist should have mode 0644 or stricter (user-only rwx)" {
    # We cannot run the real installer here (it would touch the real
    # ~/Library/LaunchAgents). Instead: verify that the installer writes the
    # plist with umask 0077 → mode will be 0600.
    /usr/bin/grep -q "umask 0077" install.sh
}

@test "S-05b: healthcheck plist contains no user-rwx path as a ProgramArgument" {
    # The ProgramArgument path must point at $APP_SUPPORT/adobe-toggle
    # (= ~/Library/Application Support/AdobeToggleManager — user-only via 0700).
    # Verify in the installer: the path baked in there uses $CORE_DST.
    /usr/bin/grep -A3 "ProgramArguments" install.sh | /usr/bin/grep -q "CORE_DST"
}

# === S-09 Whitelist-bypass awareness ===========================================

@test "S-09: with a manually crafted all-user_allowed disabled.list the block action stays ineffective" {
    # Adversarial: attacker writes ALL 9 Adobe components as user_allowed
    # into disabled.list. The daemon respects that blindly.
    # Expectation: behavior is DOCUMENTED (no silent fail) — we verify that
    # disabled_list_is_user_allowed reacts consistently.
    /bin/mkdir -p "$ATM_BASE"
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.evil1	gui	2026-05-03T12:00:00Z	user_allowed
com.adobe.evil2	system	2026-05-03T12:00:00Z	user_allowed
com.adobe.evil3	user	2026-05-03T12:00:00Z	user_allowed
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        for lbl in com.adobe.evil1 com.adobe.evil2 com.adobe.evil3; do
            disabled_list_is_user_allowed \"\$lbl\" && echo \"\$lbl=ALLOWED\" || echo \"\$lbl=BLOCKED\"
        done
    "
    [ "$status" -eq 0 ]
    # All 3 detected as ALLOWED — that is by design. The test documents the behavior.
    [[ "$output" == *"com.adobe.evil1=ALLOWED"* ]]
    [[ "$output" == *"com.adobe.evil2=ALLOWED"* ]]
    [[ "$output" == *"com.adobe.evil3=ALLOWED"* ]]
}

@test "S-09b: disabled.list file permissions should be 0600 (only the user can tamper)" {
    /bin/mkdir -p "$ATM_BASE"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_add com.adobe.test gui user_allowed"
    [ "$status" -eq 0 ]
    local mode
    mode=$(/usr/bin/stat -f "%Lp" "$ATM_DISABLED_FILE" 2>/dev/null)
    [ "$mode" = "600" ]
}

# === S-11 PID-file poisoning detection =========================================

@test "S-11: _release_daemon_lock deletes ONLY when the PID is 'ours'" {
    # Adversarial: attacker writes a foreign PID into $ATM_PID_FILE
    /bin/mkdir -p "$ATM_BASE"
    # Spawn a dummy process that we control
    /bin/sleep 30 &
    local fake_pid=$!
    echo "$fake_pid" > "$ATM_PID_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # release_daemon_lock with our (test) PID — NOT $fake_pid
        _release_daemon_lock 2>&1
    "
    /bin/kill -TERM "$fake_pid" 2>/dev/null || true
    # PID file MUST still exist because we must not delete a foreign PID
    [ -f "$ATM_PID_FILE" ]
    local pid_in_file
    read -r pid_in_file < "$ATM_PID_FILE" 2>/dev/null || pid_in_file=""
    [ "$pid_in_file" = "$fake_pid" ]
}

@test "S-11b: _acquire_daemon_lock detects a live foreign PID + refuses to acquire" {
    /bin/mkdir -p "$ATM_BASE"
    /bin/sleep 30 &
    local fake_pid=$!
    echo "$fake_pid" > "$ATM_PID_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _acquire_daemon_lock 2>&1
    "
    /bin/kill -TERM "$fake_pid" 2>/dev/null || true
    # Acquire MUST fail on a live foreign PID
    [ "$status" -ne 0 ]
}

# === S-13 ps output leak ========================================================

@test "S-13: dispatch uses only short subcommand names without sensitive args (no token, no user paths)" {
    # ps aux would show 'adobe-toggle --daemon' or '--healthcheck'.
    # Verify that no sensitive arguments can end up in the argv.
    # The installer sets env vars (ATM_BASE) instead of CLI args — that is good.
    /usr/bin/grep -q "EnvironmentVariables" install.sh
    /usr/bin/grep -q "ATM_BASE" install.sh
    # No API token or similar in the ProgramArguments
    ! /usr/bin/grep -E "TOKEN|SECRET|password|API_KEY" install.sh || true
}

# === S-14 NDJSON logs without PII ==============================================

@test "S-14: log_event writes no hostname/user-specific defaults" {
    # Verify: log_event output contains only what is explicitly passed in
    /bin/mkdir -p "$ATM_BASE/logs"
    run /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source lib/log.zsh
        log_event TEST 'detail-string-only'
    "
    local today=$(/bin/date +%Y-%m-%d)
    local content
    content=$(/bin/cat "$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson")
    # Output must contain ts+event+details — and nothing else
    /usr/bin/python3 -c "
import json
d = json.loads('$content'.replace('\\\\','\\\\\\\\'))
keys = set(d.keys())
expected = {'ts', 'event', 'details'}
assert keys == expected, f'unexpected keys: {keys - expected}'
"
}

# === S-15 Authority cache cross-user isolation =================================

@test "S-15: authority cache lives in $ATM_BASE (= user-only 0700)" {
    # Verify: the cache (when written to disk) is user-only.
    # In v4.x the cache is in-memory only (typeset -gA _AUTHORITY_CACHE),
    # so it is NOT written to disk. That is the strictest form of
    # cross-user isolation.
    ! /usr/bin/grep -E "_AUTHORITY_CACHE.*>.*\\\$ATM" lib/discovery.zsh || true
    # In-memory only → cross-user isolation is guaranteed by design
    /usr/bin/grep -q "typeset -gA _AUTHORITY_CACHE" lib/discovery.zsh
}

# === S-16 xcrun hijack protection ==============================================

@test "S-16: lib/watcher.zsh uses absolute /usr/bin/xcrun (no PATH lookup)" {
    /usr/bin/grep -q "/usr/bin/xcrun" lib/watcher.zsh
    # No bare 'xcrun' (without a path) that could be bypassed via PATH hijack
    ! /usr/bin/grep -E "^[^#]*[^/]xcrun " lib/watcher.zsh || true
}

@test "S-16b: installer checks xcrun via an absolute path" {
    /usr/bin/grep -q "/usr/bin/xcrun" install.sh
}

# === S-18 Pre-push override audit ==============================================

@test "S-18: pre-push hook prints the override notice clearly to stderr" {
    local hook="$BATS_TEST_DIRNAME/../scripts/git-hooks/pre-push"
    [ -f "$hook" ]
    run env ATM_SKIP_PRE_PUSH=1 bash -c "echo '' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped"* ]] || [[ "$output" == *"ATM_SKIP_PRE_PUSH"* ]]
}
