#!/usr/bin/env bats
# INST.3: source-side logs/ symlink is gated on the source tree being a git
# working copy. Outside a repo (extracted tarball / arbitrary download dir) the
# symlink is skipped — logs stay reachable at $APP_SUPPORT/logs.
#
# Harness: copy installer with 'main "$@"' stripped, override SRC_DIR + ATM_BASE
# into tempdirs, call phase_appsupport in a zsh subshell.

setup() {
    INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
    [ -f "$INSTALLER" ]
    TMPROOT=$(mktemp -d -t atm_symlink_guard_XXXXXX)
    SRC="$TMPROOT/src"
    DEST="$TMPROOT/appsupport"
    mkdir -p "$SRC"
    # SRC_DIR is 'typeset -gr' in the installer → strip the readonly so the test
    # can override it, alongside stripping main.
    /usr/bin/sed \
        -e 's|^main "\$@"|# main disabled in test|' \
        -e 's|^typeset -gr SRC_DIR=.*$|typeset -g SRC_DIR="${ATM_TEST_SRC_DIR:?}"|' \
        "$INSTALLER" > "$TMPROOT/installer.sh"
}

teardown() {
    [[ -n "${TMPROOT:-}" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"
}

@test "logs symlink: SKIPPED when SRC_DIR is not a git repo" {
    # SRC has no .git → arbitrary download dir
    run /bin/zsh -c "ATM_TEST_SRC_DIR='$SRC' ATM_BASE='$DEST' source '$TMPROOT/installer.sh' >/dev/null 2>&1; ATM_TEST_SRC_DIR='$SRC' ATM_BASE='$DEST' phase_appsupport 2>&1"
    [ "$status" -eq 0 ]
    # No symlink was created in the source tree
    [ ! -L "$SRC/logs" ]
    [ ! -e "$SRC/logs" ]
    # App-Support logs dir still exists (logs reachable there)
    [ -d "$DEST/logs" ]
}

@test "logs symlink: CREATED when SRC_DIR is a git working copy" {
    mkdir -p "$SRC/.git"
    run /bin/zsh -c "ATM_TEST_SRC_DIR='$SRC' ATM_BASE='$DEST' source '$TMPROOT/installer.sh' >/dev/null 2>&1; ATM_TEST_SRC_DIR='$SRC' ATM_BASE='$DEST' phase_appsupport 2>&1"
    [ "$status" -eq 0 ]
    [ -L "$SRC/logs" ]
    [ "$(/usr/bin/stat -f '%Y' "$SRC/logs")" = "$DEST/logs" ]
}

@test "logs symlink: skip emits informational note (logs path)" {
    run /bin/zsh -c "ATM_TEST_SRC_DIR='$SRC' ATM_BASE='$DEST' source '$TMPROOT/installer.sh' >/dev/null 2>&1; ATM_TEST_SRC_DIR='$SRC' ATM_BASE='$DEST' phase_appsupport 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"logs"* ]]
}
