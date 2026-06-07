#!/usr/bin/env bash
# Sandbox lifecycle for Adobe Toggle bats tests.
# Each test gets a fresh ATM_BASE under /tmp + isolated mock-binaries.
# All ATM_LAUNCHCTL_BIN / ATM_CODESIGN_BIN calls are redirected to mocks
# that log every invocation to $ATM_MOCK_LOG_DIR for assertions.
#
# Usage in a .bats file:
#   load helpers/sandbox.bash
#   setup() { sandbox_setup; }
#   teardown() { sandbox_teardown; }
#
# After setup, the following are exported and ready:
#   ATM_BASE                 fresh tempdir
#   ATM_LAUNCHCTL_BIN        path to mock_launchctl
#   ATM_CODESIGN_BIN         path to mock_codesign
#   ATM_LAUNCHCTL_REAL_DENY  set to "1" (hard-guard active)
#   ATM_MOCK_LOG_DIR         tempdir holding launchctl.log + codesign.log
#   ATM_MOCK_CODESIGN_DB     TSV file: binary_path\tauthority
#   SCRIPT                   absolute path to adobe-toggle

# Resolve once — bats sets BATS_TEST_DIRNAME = the dir containing the .bats file
_HELPERS_DIR="${BATS_TEST_DIRNAME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/helpers"
[[ -d "$_HELPERS_DIR" ]] || _HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sandbox_setup() {
    export ATM_BASE
    ATM_BASE="$(mktemp -d -t adobe_toggle_test_XXXXXX)"

    export ATM_MOCK_LOG_DIR="$ATM_BASE/_mocks"
    mkdir -p "$ATM_MOCK_LOG_DIR"
    : > "$ATM_MOCK_LOG_DIR/launchctl.log"
    : > "$ATM_MOCK_LOG_DIR/codesign.log"

    # Codesign mock looks up authority by binary path here.
    # Test populates this via codesign_db_add or sandbox_codesign_set.
    export ATM_MOCK_CODESIGN_DB="$ATM_MOCK_LOG_DIR/codesign_db.tsv"
    : > "$ATM_MOCK_CODESIGN_DB"

    export ATM_LAUNCHCTL_BIN="$_HELPERS_DIR/mocks/mock_launchctl"
    export ATM_CODESIGN_BIN="$_HELPERS_DIR/mocks/mock_codesign"

    # Hard-guard for the test suite: refuse real launchctl with com.adobe.* args.
    # Since we point ATM_LAUNCHCTL_BIN at the mock, the guard inside _launchctl
    # would never fire — but if a test bug accidentally restores the default,
    # the guard catches it.
    export ATM_LAUNCHCTL_REAL_DENY=1

    # v4.19.2: sudo mock + hard-guard analogous to the launchctl pattern. mock_sudo
    # delegates non-Adobe args to the arguments (so that `sudo $LAUNCHCTL ...`
    # → becomes a mock_launchctl call). REAL_DENY=1 catches accidental real sudo.
    export ATM_SUDO_BIN="$_HELPERS_DIR/mocks/mock_sudo"
    export ATM_SUDO_REAL_DENY=1
    : > "$ATM_MOCK_LOG_DIR/sudo.log"

    # PAM file overrides — default to empty sandbox files (= no Touch ID).
    # Tests use pam_tid_enable / pam_tid_disable to flip state.
    mkdir -p "$ATM_BASE/_pam"
    export ATM_PAM_SUDO_FILE="$ATM_BASE/_pam/sudo"
    export ATM_PAM_SUDO_LOCAL_FILE="$ATM_BASE/_pam/sudo_local"
    : > "$ATM_PAM_SUDO_FILE"
    : > "$ATM_PAM_SUDO_LOCAL_FILE"

    export SCRIPT="$BATS_TEST_DIRNAME/../adobe-toggle"
    [[ -f "$SCRIPT" ]] || SCRIPT="$_HELPERS_DIR/../adobe-toggle"

    # Pluginkit-Helper sandboxing (v4.2.0): mock binary + DB-File + hard-guard.
    export ATM_PLUGINKIT_BIN="$_HELPERS_DIR/mocks/mock_pluginkit"
    export ATM_PLUGINKIT_REAL_DENY=1
    export ATM_MOCK_PLUGINKIT_DB="$ATM_MOCK_LOG_DIR/pluginkit_db.txt"
    : > "$ATM_MOCK_PLUGINKIT_DB"
    : > "$ATM_MOCK_LOG_DIR/pluginkit.log"
    export PLUGINKIT_HELPER="$BATS_TEST_DIRNAME/../scripts/pluginkit-sweep.sh"
    [[ -f "$PLUGINKIT_HELPER" ]] || PLUGINKIT_HELPER="$_HELPERS_DIR/../../scripts/pluginkit-sweep.sh"

    # FSEvents watcher mock (v4.5.0). Tests sandbox the atm-watcher binary
    # via ATM_WATCHER_BIN so that no real FSEventStream runs on system paths.
    export ATM_WATCHER_BIN="$_HELPERS_DIR/mocks/mock_atm_watcher"
}

# Enable Touch-ID-for-sudo in the sandbox PAM files.
# Optional 2nd arg: which file to write to ("sudo" | "sudo_local"; default "sudo_local").
pam_tid_enable() {
    local target="${1:-sudo_local}"
    local file
    case "$target" in
        sudo) file="$ATM_PAM_SUDO_FILE" ;;
        sudo_local) file="$ATM_PAM_SUDO_LOCAL_FILE" ;;
        *) echo "pam_tid_enable: unknown target '$target'"; return 1 ;;
    esac
    cat > "$file" <<'EOF'
# sandbox PAM file with Touch ID enabled
auth       sufficient     pam_tid.so
auth       sufficient     pam_smartcard.so
auth       required       pam_opendirectory.so
account    required       pam_permit.so
password   required       pam_deny.so
session    required       pam_permit.so
EOF
}

# Disable Touch-ID-for-sudo in the sandbox PAM files (clear both).
pam_tid_disable() {
    : > "$ATM_PAM_SUDO_FILE"
    : > "$ATM_PAM_SUDO_LOCAL_FILE"
}

sandbox_teardown() {
    [[ -n "${ATM_BASE:-}" && -d "$ATM_BASE" ]] && rm -rf "$ATM_BASE"
    unset ATM_BASE ATM_MOCK_LOG_DIR ATM_MOCK_CODESIGN_DB
    unset ATM_LAUNCHCTL_BIN ATM_CODESIGN_BIN ATM_LAUNCHCTL_REAL_DENY
    unset ATM_SUDO_BIN ATM_SUDO_REAL_DENY ATM_MOCK_SUDO_FAIL ATM_MOCK_SUDO_NOPASSWD
    unset ATM_PAM_SUDO_FILE ATM_PAM_SUDO_LOCAL_FILE
    unset ATM_PLUGINKIT_BIN ATM_PLUGINKIT_REAL_DENY ATM_MOCK_PLUGINKIT_DB
    unset PLUGINKIT_HELPER ATM_MOCK_PLUGINKIT_FAIL
    unset ATM_WATCHER_BIN ATM_MOCK_WATCHER_USR1_AFTER ATM_MOCK_WATCHER_FAIL
}

# Set the mock pluginkit DB to a multi-line string in `pluginkit -m -A -v` format.
# Lines like:  +    com.adobe.foo(1.2.3)\tUUID\t2026-04-23 19:38:15 +0000\t/path/to/foo.appex
#   pluginkit_db_set "$(printf '+    com.adobe.foo(1.0)\tUUID\tdate\t/p/foo\n')"
pluginkit_db_set() {
    printf '%s\n' "$1" > "$ATM_MOCK_PLUGINKIT_DB"
}

# Read all logged pluginkit calls.
pluginkit_log() {
    cat "$ATM_MOCK_LOG_DIR/pluginkit.log"
}

# Add an entry to the codesign mock database.
#   codesign_db_add <binary-path> <authority-string>
codesign_db_add() {
    local binary="$1" authority="$2"
    printf '%s\t%s\n' "$binary" "$authority" >> "$ATM_MOCK_CODESIGN_DB"
}

# Read all logged launchctl calls (one per line, tab-separated args).
launchctl_log() {
    cat "$ATM_MOCK_LOG_DIR/launchctl.log"
}

# v4.19.2: Read all logged sudo calls.
sudo_log() {
    cat "$ATM_MOCK_LOG_DIR/sudo.log"
}

# Read all logged codesign calls.
codesign_log() {
    cat "$ATM_MOCK_LOG_DIR/codesign.log"
}

# Assertion: expect exactly N launchctl calls with the given subcommand.
#   assert_launchctl_called <subcommand> <expected-count>
assert_launchctl_called() {
    local subcmd="$1" expected="$2"
    # grep -c writes "0" to stdout AND exits 1 when no matches.
    # Use awk to count lines safely (always exits 0).
    local actual
    actual=$(awk -v s="${subcmd}" 'BEGIN{n=0} index($0, s"\t")==1 {n++} END{print n}' "$ATM_MOCK_LOG_DIR/launchctl.log" 2>/dev/null)
    actual="${actual:-0}"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: expected $expected launchctl '$subcmd' calls, got $actual"
        echo "--- launchctl.log ---"
        cat "$ATM_MOCK_LOG_DIR/launchctl.log"
        return 1
    fi
    return 0
}

# Count lines in a log file matching a pattern. Always returns a number.
# Usage: count=$(count_log_lines launchctl '^enable')
count_log_lines() {
    local logname="$1" pattern="$2"
    local logfile="$ATM_MOCK_LOG_DIR/${logname}.log"
    [[ -f "$logfile" ]] || { echo 0; return 0; }
    awk -v p="$pattern" 'BEGIN{n=0} $0 ~ p {n++} END{print n}' "$logfile" 2>/dev/null
}

# Create a minimal Adobe-style plist under a directory.
#   mock_plist_create <dir> <label>
mock_plist_create() {
    local dir="$1" label="$2"
    mkdir -p "$dir"
    cat > "$dir/${label}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
</dict>
</plist>
EOF
}

# Force ATM_LAUNCHCTL_BIN to a specific path (for tests that need to verify
# the guard fires when the real launchctl would be called).
sandbox_use_real_launchctl_bin() {
    export ATM_LAUNCHCTL_BIN="/bin/launchctl"
}
