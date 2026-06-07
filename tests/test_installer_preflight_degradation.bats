#!/usr/bin/env bats
# Graceful-degradation tests for phase_preflight (INST.1).
# Proves: when CLT-dependent tools (codesign / PlistBuddy / xcrun) are absent,
# install proceeds (exit 0) with a single actionable warning, instead of the
# old fatal abort. Truly-mandatory bins (launchctl/osascript/security/sw_vers/
# pluginkit) stay on their real system paths so they still pass.
#
# Harness mirrors test_installer_preflight.bats: copy installer to tempdir with
# 'main "$@"' stripped, populate full lib/ tree, source + call phase_preflight.
# Degradation is injected via the ATM_*_BIN override hooks (INST.1) pointing at
# a nonexistent path.

REQUIRED_LIB=(log.zsh state.zsh disabled_list.zsh bloat.zsh discovery.zsh config.zsh notify.zsh pam.zsh tui.zsh daemon.zsh box.zsh watcher.zsh backend_registry.zsh json.zsh whitelist.zsh)
REQUIRED_BACKENDS=(_interface.zsh launchd.zsh pluginkit.zsh)

setup() {
    INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
    [ -f "$INSTALLER" ]
    TMPDIR_PRE=$(mktemp -d -t atm_preflight_degr_XXXXXX)
    /usr/bin/sed -e 's|^main "\$@"|# main disabled in test|' "$INSTALLER" > "$TMPDIR_PRE/installer.sh"
    : > "$TMPDIR_PRE/adobe-toggle"
    # nonexistent override target — guaranteed not -x
    NOPE="$TMPDIR_PRE/_nonexistent_clt_bin"
}

teardown() {
    [[ -n "${TMPDIR_PRE:-}" && -d "$TMPDIR_PRE" ]] && rm -rf "$TMPDIR_PRE"
}

populate_full_lib() {
    mkdir -p "$TMPDIR_PRE/lib/backends"
    local f
    for f in "${REQUIRED_LIB[@]}"; do : > "$TMPDIR_PRE/lib/$f"; done
    for f in "${REQUIRED_BACKENDS[@]}"; do : > "$TMPDIR_PRE/lib/backends/$f"; done
}

@test "preflight: codesign+PlistBuddy absent → exit 0 (warning, not abort)" {
    populate_full_lib
    run /bin/zsh -c "ATM_CODESIGN_BIN='$NOPE' ATM_PLISTBUDDY_BIN='$NOPE' source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; ATM_CODESIGN_BIN='$NOPE' ATM_PLISTBUDDY_BIN='$NOPE' phase_preflight"
    [ "$status" -eq 0 ]
}

@test "preflight: missing CLT bins emit warning naming xcode-select --install" {
    populate_full_lib
    # also kill xcode-select so the top-level CLT warning fires (full CLT-miss)
    run /bin/zsh -c "ATM_XCODE_SELECT_BIN='$NOPE' ATM_CODESIGN_BIN='$NOPE' ATM_PLISTBUDDY_BIN='$NOPE' ATM_XCRUN_BIN='$NOPE' source '$TMPDIR_PRE/installer.sh' 2>&1; ATM_XCODE_SELECT_BIN='$NOPE' ATM_CODESIGN_BIN='$NOPE' ATM_PLISTBUDDY_BIN='$NOPE' ATM_XCRUN_BIN='$NOPE' phase_preflight 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"xcode-select --install"* ]]
    [[ "$output" == *"continuing"* ]]
}

@test "preflight: mandatory bins still fatal (sanity — degradation is scoped)" {
    # Repoint a TRULY-mandatory bin (launchctl) at nothing → must still abort.
    # Proves the split did not turn the whole bin-check into warnings.
    populate_full_lib
    run /bin/zsh -c "source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; MANDATORY_SYSTEM_BINS=('$NOPE'); phase_preflight 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"installation aborted"* ]]
}
