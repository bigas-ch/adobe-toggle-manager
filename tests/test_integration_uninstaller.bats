#!/usr/bin/env bats
# Integration test for uninstall.sh.
# Strategy: use DRY-RUN mode so no launchctl/rm runs against the real system.
# Verifies that every phase output names the expected removal targets. Whenever
# the installer evolves (new paths under APP_SUPPORT, new plists, new symlinks)
# the uninstaller MUST be updated alongside it — these tests catch the drift when
# uninstaller patterns no longer match the installer patterns.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    export UNINSTALLER="$BATS_TEST_DIRNAME/../uninstall.sh"
    [ -f "$UNINSTALLER" ] || UNINSTALLER="$_HELPERS_DIR/../uninstall.sh"
    export INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
    [ -f "$INSTALLER" ] || INSTALLER="$_HELPERS_DIR/../install.sh"
}
teardown() { sandbox_teardown; }

@test "uninstaller exists, executable, syntactically valid zsh" {
    [ -f "$UNINSTALLER" ]
    [ -x "$UNINSTALLER" ]
    run /bin/zsh -n "$UNINSTALLER"
    [ "$status" -eq 0 ]
}

@test "uninstaller respects ATM_BASE override" {
    grep -q 'ATM_BASE' "$UNINSTALLER"
}

@test "uninstaller dry-run with FORCE + BACKUP_LOGS=no completes all 9 phases" {
    run env \
        ATM_UNINSTALL_DRY_RUN=1 \
        ATM_UNINSTALL_FORCE=1 \
        ATM_UNINSTALL_BACKUP_LOGS=no \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    # all 9 phase headers in the output
    [[ "$output" == *"Phase: confirm"* ]]
    [[ "$output" == *"Phase: release_adobe"* ]]
    [[ "$output" == *"Phase: backup_logs"* ]]
    [[ "$output" == *"Phase: bootout"* ]]
    [[ "$output" == *"Phase: kill_processes"* ]]
    [[ "$output" == *"Phase: plists"* ]]
    [[ "$output" == *"Phase: appsupport"* ]]
    [[ "$output" == *"Phase: src_symlink"* ]]
    [[ "$output" == *"Phase: summary"* ]]
    [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "uninstaller targets both LaunchAgent labels (daemon + healthcheck)" {
    grep -q 'com.user.adobe-toggle.daemon' "$UNINSTALLER"
    grep -q 'com.user.adobe-toggle.healthcheck' "$UNINSTALLER"
}

@test "uninstaller targets AdobeToggleManager runtime dir" {
    grep -qE 'AdobeToggleManager|APP_SUPPORT' "$UNINSTALLER"
}

@test "uninstaller has release-before-bootout phase (avoids zombie disabled.list)" {
    grep -q 'phase_release_adobe' "$UNINSTALLER"
    grep -q 'state.*allow' "$UNINSTALLER"
    grep -q 'SIGUSR1\|kill -USR1' "$UNINSTALLER"
}

@test "uninstaller has interactive backup-logs prompt with default Y" {
    grep -q 'backup_logs\|BACKUP_LOGS' "$UNINSTALLER"
    grep -q 'Back up\|backup' "$UNINSTALLER"
    # default path exists as template
    grep -q '_uninstall_backup' "$UNINSTALLER"
}

@test "uninstaller uses [a]dobe-trick to avoid pgrep-self-match" {
    grep -qE '\[a\]dobe_toggle' "$UNINSTALLER"
    grep -qE '\[a\]tm-watcher' "$UNINSTALLER"
}

@test "uninstaller dry-run shows bootout for both labels" {
    run env \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 ATM_UNINSTALL_BACKUP_LOGS=no \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    # Daemon label must be named in the output (even if not loaded — the string must be there)
    [[ "$output" == *"com.user.adobe-toggle.daemon"* ]]
    [[ "$output" == *"com.user.adobe-toggle.healthcheck"* ]]
}

@test "uninstaller dry-run shows rm for both plist files" {
    run env \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 ATM_UNINSTALL_BACKUP_LOGS=no \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"adobe-toggle.daemon.plist"* ]]
    [[ "$output" == *"adobe-toggle.healthcheck.plist"* ]]
}

@test "uninstaller dry-run shows appsupport rm-rf when target dir exists" {
    /bin/mkdir -p "$ATM_BASE/fake-app-support/logs"
    run env \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 ATM_UNINSTALL_BACKUP_LOGS=no \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rm -rf"* ]] || [[ "$output" == *"[DRY] /bin/rm -rf"* ]]
    [[ "$output" == *"fake-app-support"* ]]
}

@test "uninstaller dry-run skips backup_logs when no logs dir" {
    run env \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 \
        ATM_BASE="$ATM_BASE/no-such-dir" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no logs found"* ]]
}

@test "uninstaller honors ATM_UNINSTALL_BACKUP_LOGS=<absolute-path>" {
    /bin/mkdir -p "$ATM_BASE/fake-app-support/logs"
    /bin/echo "fake-log-content" > "$ATM_BASE/fake-app-support/logs/test.log"
    local backup_target="$ATM_BASE/my-backup"
    run env \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 \
        ATM_UNINSTALL_BACKUP_LOGS="$backup_target" \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$backup_target"* ]]
}

@test "uninstaller rejects ATM_UNINSTALL_BACKUP_LOGS=relative-path" {
    /bin/mkdir -p "$ATM_BASE/fake-app-support/logs"
    run env \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 \
        ATM_UNINSTALL_BACKUP_LOGS="relative/path" \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute-path"* ]] || [[ "$output" == *"absolute"* ]]
}

@test "uninstaller respects ATM_UNINSTALL_SKIP_RELEASE flag" {
    /bin/mkdir -p "$ATM_BASE/fake-app-support"
    /bin/echo "block" > "$ATM_BASE/fake-app-support/state"
    /bin/echo "#!/bin/sh" > "$ATM_BASE/fake-app-support/adobe-toggle"
    run env \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 ATM_UNINSTALL_BACKUP_LOGS=no \
        ATM_UNINSTALL_SKIP_RELEASE=1 \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped"* ]] || [[ "$output" == *"SKIP_RELEASE"* ]]
    # In skip mode the state must NOT be changed to allow (dry-run anyway, but the log output is checked)
    [[ "$output" != *"state → allow"* ]]
}

# === Drift detection: installer paths must be mirrorable in the uninstaller ===
# When the installer creates a new path, this test fires as soon as the path is
# not addressed in the uninstaller. That is the "sealing" obligation.

@test "drift: installer's PLIST_PATH is in uninstaller" {
    # Both files reference com.user.adobe-toggle.daemon.plist
    grep -q 'com.user.adobe-toggle.daemon.plist' "$INSTALLER"
    grep -q 'com.user.adobe-toggle.daemon.plist' "$UNINSTALLER"
}

@test "drift: installer's HEALTHCHECK_PLIST_PATH is in uninstaller" {
    grep -q 'com.user.adobe-toggle.healthcheck.plist' "$INSTALLER"
    grep -q 'com.user.adobe-toggle.healthcheck.plist' "$UNINSTALLER"
}

@test "drift: installer's APP_SUPPORT path is in uninstaller" {
    grep -q 'AdobeToggleManager' "$INSTALLER"
    grep -q 'AdobeToggleManager' "$UNINSTALLER"
}

@test "drift: installer's source-side logs symlink is in uninstaller" {
    # Installer sets the $SCRIPT_DIR/logs symlink → uninstaller must know about it
    grep -qE 'SRC_DIR.*logs|src_logs' "$INSTALLER"
    grep -qE 'SRC_SYMLINK|SCRIPT_DIR.*logs' "$UNINSTALLER"
}

# === v1.1.0: inline sudo-unsweep for system scope ===

@test "v1.1.0: uninstaller release_adobe does inline sudo-unsweep for system items" {
    # Instead of just a WARN hint, release_adobe must itself call sudo /bin/launchctl enable
    grep -qE 'sudo[[:space:]]+/bin/launchctl[[:space:]]+enable[[:space:]]+"system/' "$UNINSTALLER"
}

@test "v1.1.0: uninstaller filters out user_allowed during sudo-unsweep" {
    # User intent stays: user_allowed items are NOT enabled, they remain in disabled.list
    grep -qE 'state.*==.*user_allowed|user_allowed.*continue' "$UNINSTALLER"
}

@test "v1.1.0: uninstaller doc hint points to [e] Sudo-Unsweep, not [u]" {
    # Before: print "in the TUI: [u] for Sudo-Sweep" — wrong (that one is DISABLED).
    # Correct: [e] Sudo-Unsweep + [a] Allow.
    grep -qE '\[e\][[:space:]]+(Sudo-Unsweep|Allow)' "$UNINSTALLER"
    # The wrong string must NOT be present anymore (regression guard)
    ! grep -qE '\[u\][[:space:]]+for[[:space:]]+Sudo-Sweep,[[:space:]]+then[[:space:]]+\[a\]' "$UNINSTALLER"
}

@test "v1.1.0: uninstaller header shows version 1.1.0" {
    grep -qE '^# Version: 1\.1\.0' "$UNINSTALLER"
}

@test "VERS.3: default backup path is neutral (no private dev tree)" {
    # Must NOT hardcode Micha's private project tree.
    ! grep -qE 'Documents/Projekte/Adobe_Toggle' "$UNINSTALLER"
    # Default target must derive from a neutral, guaranteed-writable location.
    grep -qE 'default_target="\$\{TMPDIR' "$UNINSTALLER"
}

@test "VERS.3: dry-run with FORCE writes backup default under TMPDIR" {
    /bin/mkdir -p "$ATM_BASE/fake-app-support/logs"
    /bin/echo "fake-log" > "$ATM_BASE/fake-app-support/logs/test.log"
    run env \
        TMPDIR="$ATM_BASE/tmp/" \
        ATM_UNINSTALL_DRY_RUN=1 ATM_UNINSTALL_FORCE=1 \
        ATM_UNINSTALL_BACKUP_LOGS=yes \
        ATM_BASE="$ATM_BASE/fake-app-support" \
        "$UNINSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$ATM_BASE/tmp/"* ]]
    # Scope the dev-tree check to the BACKUP TARGET line only. A whole-$output
    # check is coupled to the runtime SCRIPT_DIR (= the user's own checkout path,
    # echoed by the confirm/summary phases); on a public install that is never
    # under Documents/Projekte, so asserting against $output would only test
    # where THIS repo physically sits, not the backup behaviour. The source code
    # itself is already guarded by the "default backup path is neutral" test.
    backup_line="$(printf '%s\n' "$output" | grep -- 'backed up')"
    [[ -n "$backup_line" ]]
    [[ "$backup_line" != *"Documents/Projekte"* ]]
}
