#!/usr/bin/env bats
# Unit tests for phase_preflight in install.sh (v4.6.0).
# Strategy: copy installer to tempdir, strip 'main "$@"' so source-only is safe,
# create faked lib/ tree, then call phase_preflight in zsh-subshell.

load helpers/sandbox.bash

# Mandatory inventory — must match the REQUIRED_LIB_FILES/REQUIRED_BACKEND_FILES
# list in the installer. When those grow there, this list has to grow with them
# (no default-sharing possible because typeset -gar is readonly).
REQUIRED_LIB=(log.zsh state.zsh disabled_list.zsh bloat.zsh discovery.zsh config.zsh notify.zsh pam.zsh tui.zsh daemon.zsh box.zsh watcher.zsh backend_registry.zsh json.zsh whitelist.zsh)
REQUIRED_BACKENDS=(_interface.zsh launchd.zsh pluginkit.zsh)

setup() {
    INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
    [ -f "$INSTALLER" ]
    TMPDIR_PRE=$(mktemp -d -t atm_preflight_XXXXXX)
    # Copy installer with main-call stripped
    /usr/bin/sed -e 's|^main "\$@"|# main disabled in test|' "$INSTALLER" > "$TMPDIR_PRE/installer.sh"
    # Always create the core-script stub (preflight doesn't check it, but main does)
    : > "$TMPDIR_PRE/adobe-toggle"
}

teardown() {
    [[ -n "${TMPDIR_PRE:-}" && -d "$TMPDIR_PRE" ]] && rm -rf "$TMPDIR_PRE"
}

# Helper: populate full lib/ tree with empty stubs
populate_full_lib() {
    mkdir -p "$TMPDIR_PRE/lib/backends"
    local f
    for f in "${REQUIRED_LIB[@]}"; do : > "$TMPDIR_PRE/lib/$f"; done
    for f in "${REQUIRED_BACKENDS[@]}"; do : > "$TMPDIR_PRE/lib/backends/$f"; done
}

@test "preflight: all required files present → exit 0" {
    populate_full_lib
    run /bin/zsh -c "source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; phase_preflight"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lib inventory"* || "$output" == *"lib/log.zsh"* ]]
}

@test "preflight: missing lib/log.zsh → exit 1, error mentions log.zsh" {
    populate_full_lib
    rm "$TMPDIR_PRE/lib/log.zsh"
    run /bin/zsh -c "source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; phase_preflight"
    [ "$status" -eq 1 ]
    [[ "$output" == *"lib/log.zsh missing"* ]]
}

@test "preflight: missing lib/backends/launchd.zsh → exit 1, error mentions launchd.zsh" {
    populate_full_lib
    rm "$TMPDIR_PRE/lib/backends/launchd.zsh"
    run /bin/zsh -c "source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; phase_preflight"
    [ "$status" -eq 1 ]
    [[ "$output" == *"lib/backends/launchd.zsh missing"* ]]
}

@test "preflight: empty lib/ → exit 1, ALL 18 files reported (collect-all-errors design)" {
    mkdir -p "$TMPDIR_PRE/lib/backends"
    run /bin/zsh -c "source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; phase_preflight"
    [ "$status" -eq 1 ]
    # 15 lib + 3 backends = 18 missing (lib/bloat.zsh added in v1.1.0)
    local count
    count=$(echo "$output" | /usr/bin/grep -c "missing in source tree")
    [ "$count" -eq 18 ]
}

@test "preflight: macOS-version detected (real system has sw_vers)" {
    populate_full_lib
    run /bin/zsh -c "source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; phase_preflight"
    [ "$status" -eq 0 ]
    [[ "$output" == *"macOS"* ]]
}

@test "preflight: PlistBuddy is at /usr/libexec/ (drift-protection)" {
    # Guard against memory drift where /usr/bin/PlistBuddy used to be referenced.
    /usr/bin/grep -q '/usr/libexec/PlistBuddy' "$INSTALLER"
}

@test "preflight: Xcode CLT detected on real system" {
    populate_full_lib
    run /bin/zsh -c "source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; phase_preflight"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode CLT"* ]]
}

@test "preflight: REQUIRED_LIB_FILES contains all 15 active lib modules" {
    # Guard against drift: if someone adds a new lib/ module but forgets to
    # extend REQUIRED_LIB_FILES, preflight would blindly skip over it.
    local actual_lib_count
    actual_lib_count=$(ls "$BATS_TEST_DIRNAME/../lib"/*.zsh 2>/dev/null | /usr/bin/wc -l | /usr/bin/awk '{print $1}')
    local declared_count="${#REQUIRED_LIB[@]}"
    [ "$actual_lib_count" -eq "$declared_count" ]
}

@test "preflight: REQUIRED_BACKEND_FILES contains all 3 active backend modules" {
    local actual_backends
    actual_backends=$(ls "$BATS_TEST_DIRNAME/../lib/backends"/*.zsh 2>/dev/null | /usr/bin/wc -l | /usr/bin/awk '{print $1}')
    local declared="${#REQUIRED_BACKENDS[@]}"
    [ "$actual_backends" -eq "$declared" ]
}

@test "preflight: appears as first phase in main loop (runs before mutations)" {
    /usr/bin/grep -qE 'for phase in preflight ' "$INSTALLER"
}

@test "verify: extended check confirms lib inventory at destination" {
    /usr/bin/grep -q "lib inventory complete" "$INSTALLER"
}

@test "preflight: relative ATM_BASE → exit 1, error names absolute path" {
    populate_full_lib
    run /bin/zsh -c "export ATM_BASE='relative/path'; source '$TMPDIR_PRE/installer.sh' >/dev/null 2>&1; phase_preflight"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ATM_BASE"* && "$output" == *"absolute"* ]]
}
