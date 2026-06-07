#!/usr/bin/env bats
# Security tests for shell hardening (Findings H-3 PIPE_FAIL, H-4 PATH-explicit,
# source-guard, set -u, IFS-pollution).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "SEC-2 FIXED (v4.1.1): set -u is restored after emulate -L zsh (NO_UNSET active)" {
    # The script now does: set -u → emulate -L zsh → setopt NO_UNSET.
    # Verify NO_UNSET is set after sourcing.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; setopt | grep -q nounset && print YES || print NO"
    [ "$status" -eq 0 ]
    [ "$output" = "YES" ]
}

@test "PIPE_FAIL is set (failed first stage propagates exit code)" {
    # After source, PIPE_FAIL must be enabled.
    # false | true normally returns 0; with PIPE_FAIL it returns the failure.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; false | true; print \$?"
    [ "$status" -eq 0 ]
    # Output is the exit code of the pipeline, must be non-zero with PIPE_FAIL
    [ "$output" != "0" ]
}

@test "PATH is reset to system binaries only" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; print -- \"\$PATH\""
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/bin:/bin:/usr/sbin:/sbin" ]
}

@test "source-guard: sourcing the script does NOT auto-run main() (no TUI start)" {
    # If main() ran, we'd expect TUI escape codes / clear / blocking input.
    # Source must complete instantly with no extra output.
    # Note: 'timeout' is not on macOS by default — use a subshell with bg+kill alternative.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; print 'sourced-ok'"
    [ "$status" -eq 0 ]
    [ "$output" = "sourced-ok" ]
}

@test "source-guard: direct execution shows --version output" {
    run zsh "$SCRIPT" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"adobe-toggle"* ]]
    # Version-agnostic: assert a semver-like major.minor.patch string is present
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "umask is 0077 (file creation defaults to 0600)" {
    # zsh emits umask without leading zero
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; umask"
    [ "$status" -eq 0 ]
    [ "$output" = "077" ]
}

@test "PATH-hijack: malicious 'launchctl' in PATH is NOT used (absolute path / hook)" {
    # Place an evil launchctl earlier in PATH and verify the script doesn't use it.
    local evil="$ATM_BASE/evilbin"
    mkdir -p "$evil"
    cat > "$evil/launchctl" <<'EOF'
#!/bin/sh
touch "$ATM_MOCK_LOG_DIR/.evil_marker"
exit 0
EOF
    chmod +x "$evil/launchctl"
    rm -f "$ATM_MOCK_LOG_DIR/.evil_marker"
    PATH="$evil:$PATH" run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; disable_launchd_label com.adobe.LegitTest user"
    [ "$status" -eq 0 ]
    # The evil launchctl must NOT have been called (no marker file)
    [ ! -f "$ATM_MOCK_LOG_DIR/.evil_marker" ]
    # And our mock launchctl IS called instead
    assert_launchctl_called bootout 1
}

@test "IFS-pollution: exotic IFS does not break write_state" {
    run zsh -c "
        IFS='|@#'
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        write_state allow
        cat \"\$ATM_STATE_FILE\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "allow" ]
}

@test "IFS-pollution: exotic IFS does not break disabled_list TSV roundtrip" {
    run zsh -c "
        IFS='|@#'
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        disabled_list_add com.adobe.X user
        disabled_list_read
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.X"* ]]
}
