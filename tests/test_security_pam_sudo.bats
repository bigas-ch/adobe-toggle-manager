#!/usr/bin/env bats
# Security tests for PAM/sudo Touch-ID detection (_touchid_for_sudo_enabled).
# All tests use the ATM_PAM_SUDO_FILE / ATM_PAM_SUDO_LOCAL_FILE ENV-Hooks
# from sandbox setup — NEVER touches the real /etc/pam.d/sudo.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "PAM ENV-Hooks point to sandbox files (never /etc/pam.d/sudo)" {
    [[ "$ATM_PAM_SUDO_FILE" == "$ATM_BASE"/* ]]
    [[ "$ATM_PAM_SUDO_LOCAL_FILE" == "$ATM_BASE"/* ]]
    [ -f "$ATM_PAM_SUDO_FILE" ]
    [ -f "$ATM_PAM_SUDO_LOCAL_FILE" ]
}

# ----- positive: Touch ID detected -----

@test "Touch ID enabled in sudo_local → _touchid_for_sudo_enabled returns 0" {
    pam_tid_enable sudo_local
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _touchid_for_sudo_enabled"
    [ "$status" -eq 0 ]
}

@test "Touch ID enabled in main sudo file → _touchid_for_sudo_enabled returns 0" {
    pam_tid_enable sudo
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _touchid_for_sudo_enabled"
    [ "$status" -eq 0 ]
}

# ----- negative: Touch ID absent -----

@test "no Touch ID anywhere → _touchid_for_sudo_enabled returns 1" {
    pam_tid_disable
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _touchid_for_sudo_enabled"
    [ "$status" -ne 0 ]
}

@test "PAM file with COMMENTED-OUT pam_tid (# auth ...) is correctly NOT detected as enabled" {
    cat > "$ATM_PAM_SUDO_LOCAL_FILE" <<'EOF'
# auth       sufficient     pam_tid.so
auth       required       pam_opendirectory.so
EOF
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _touchid_for_sudo_enabled"
    [ "$status" -ne 0 ]
}

@test "non-existent ATM_PAM_SUDO_FILE does not cause crash" {
    rm -f "$ATM_PAM_SUDO_FILE" "$ATM_PAM_SUDO_LOCAL_FILE"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _touchid_for_sudo_enabled"
    # Returns 1 (= disabled), does not crash with file-not-found error
    [ "$status" -ne 0 ]
}

@test "PAM file with pam_tid in 'session' line (not 'auth') NOT detected" {
    cat > "$ATM_PAM_SUDO_LOCAL_FILE" <<'EOF'
session    optional       pam_tid.so
EOF
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _touchid_for_sudo_enabled"
    # Validator looks for "^auth.*pam_tid" — must reject session-line.
    [ "$status" -ne 0 ]
}

@test "PAM file with leading whitespace before 'auth' NOT matched (regex anchored)" {
    cat > "$ATM_PAM_SUDO_LOCAL_FILE" <<'EOF'
   auth       sufficient     pam_tid.so
EOF
    # Regex starts with ^auth — leading spaces should NOT match.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _touchid_for_sudo_enabled"
    [ "$status" -ne 0 ]
}
