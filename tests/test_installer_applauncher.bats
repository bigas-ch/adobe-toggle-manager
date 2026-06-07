#!/usr/bin/env bats
# v1.1.0: phase_applauncher creates a double-clickable Applications launcher
# ("Adobe Toggle.app") that opens the TUI in Terminal. Non-fatal, idempotent,
# target dir overridable via ATM_APP_DIR (so the test never touches /Applications).

setup() {
    INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
    [ -f "$INSTALLER" ]
    TMPDIR_AL=$(mktemp -d -t atm_applauncher_XXXXXX)
    /usr/bin/sed -e 's|^main "\$@"|# main disabled in test|' "$INSTALLER" > "$TMPDIR_AL/installer.sh"
    APPDIR="$TMPDIR_AL/Applications"
    mkdir -p "$APPDIR"
}
teardown() { [[ -n "${TMPDIR_AL:-}" && -d "$TMPDIR_AL" ]] && rm -rf "$TMPDIR_AL"; }

@test "phase_applauncher creates an .app bundle in the target dir" {
    run env ATM_APP_DIR="$APPDIR" /bin/zsh -c "source '$TMPDIR_AL/installer.sh' >/dev/null 2>&1; phase_applauncher"
    [ "$status" -eq 0 ]
    [ -d "$APPDIR/Adobe Toggle.app" ]
    [ -f "$APPDIR/Adobe Toggle.app/Contents/Info.plist" ]
}

@test "phase_applauncher embeds the deployed TUI path (opens adobe-toggle)" {
    run env ATM_APP_DIR="$APPDIR" /bin/zsh -c "source '$TMPDIR_AL/installer.sh' >/dev/null 2>&1; phase_applauncher"
    [ "$status" -eq 0 ]
    run /usr/bin/osadecompile "$APPDIR/Adobe Toggle.app"
    [[ "$output" == *"adobe-toggle"* ]]
    [[ "$output" == *"Terminal"* ]]
}

@test "phase_applauncher is idempotent (re-run replaces, still exit 0)" {
    env ATM_APP_DIR="$APPDIR" /bin/zsh -c "source '$TMPDIR_AL/installer.sh' >/dev/null 2>&1; phase_applauncher" >/dev/null 2>&1
    run env ATM_APP_DIR="$APPDIR" /bin/zsh -c "source '$TMPDIR_AL/installer.sh' >/dev/null 2>&1; phase_applauncher"
    [ "$status" -eq 0 ]
    [ -d "$APPDIR/Adobe Toggle.app" ]
}

@test "uninstall phase_applauncher removes the launcher (co-pflege)" {
    mkdir -p "$APPDIR/Adobe Toggle.app/Contents"
    : > "$APPDIR/Adobe Toggle.app/Contents/Info.plist"
    UNINSTALLER="$BATS_TEST_DIRNAME/../uninstall.sh"
    [ -f "$UNINSTALLER" ]
    /usr/bin/sed -e 's|^main "\$@"|# main disabled in test|' "$UNINSTALLER" > "$TMPDIR_AL/uninstaller.sh"
    run env ATM_APP_DIR="$APPDIR" /bin/zsh -c "source '$TMPDIR_AL/uninstaller.sh' >/dev/null 2>&1; phase_applauncher"
    [ "$status" -eq 0 ]
    [ ! -d "$APPDIR/Adobe Toggle.app" ]
}
