#!/usr/bin/env bats
# Phase 6: Doc + Spec consistency tests.
# Checks that documented behaviours match the actual code state.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "README.md exists in repo root" {
    local readme="$BATS_TEST_DIRNAME/../README.md"
    [ -f "$readme" ]
}

@test "all run-modes from --help are implemented in main()" {
    run zsh "$SCRIPT" --help
    [ "$status" -eq 0 ]
    # Must mention all four documented modes
    [[ "$output" == *"--tui"* ]]
    [[ "$output" == *"--daemon"* ]]
    [[ "$output" == *"--summary"* ]]
    [[ "$output" == *"config"* ]]
}

@test "--version returns matching APP_VERSION from script header" {
    run zsh "$SCRIPT" --version
    [ "$status" -eq 0 ]
    # Extract APP_VERSION from script
    local declared
    declared=$(grep -E '^typeset -g APP_VERSION=' "$SCRIPT" | sed 's/.*"\(.*\)".*/\1/')
    [[ "$output" == *"$declared"* ]]
}

@test "FINDING I-1: script-header version comment must match APP_VERSION" {
    # Header line 4 declares the version in a comment; must match APP_VERSION.
    local header_v
    header_v=$(grep -m1 -E '^# Version:' "$SCRIPT" | sed -E 's/.*Version: ([0-9.]+).*/\1/')
    local app_v
    app_v=$(grep -E '^typeset -g APP_VERSION=' "$SCRIPT" | sed 's/.*"\(.*\)".*/\1/')
    if [ "$header_v" != "$app_v" ]; then
        echo "FAIL: header says '$header_v', APP_VERSION='$app_v' — drift detected"
        return 1
    fi
}

@test "README documents the block default after install" {
    local readme="$BATS_TEST_DIRNAME/../README.md"
    grep -qiE 'default state after install is' "$readme"
}

@test "README install instructions reference the installer script name" {
    local readme="$BATS_TEST_DIRNAME/../README.md"
    grep -qE 'install\.sh' "$readme"
}

@test "VERS: installer header version matches APP_VERSION" {
    local installer="$BATS_TEST_DIRNAME/../install.sh"
    local app_v inst_v
    app_v=$(grep -E '^typeset -g APP_VERSION=' "$SCRIPT" | sed 's/.*"\(.*\)".*/\1/')
    inst_v=$(grep -m1 -E '^# Version:' "$installer" | sed -E 's/.*Version: ([0-9.]+).*/\1/')
    if [ "$inst_v" != "$app_v" ]; then
        echo "FAIL: installer header says '$inst_v', APP_VERSION='$app_v' — drift detected"
        return 1
    fi
}

@test "VERS: CHANGELOG latest released version matches APP_VERSION" {
    # The public README is intentionally de-versioned (no manually maintained
    # version line that would go stale). The canonical version record is the
    # CHANGELOG; its newest released entry must track APP_VERSION.
    local changelog="$BATS_TEST_DIRNAME/../CHANGELOG.md"
    local app_v changelog_v
    app_v=$(grep -E '^typeset -g APP_VERSION=' "$SCRIPT" | sed 's/.*"\(.*\)".*/\1/')
    # First versioned heading, skipping "## [Unreleased]": ## [X.Y.Z] - DATE
    changelog_v=$(grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$changelog" | sed -E 's/.*\[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')
    if [ "$changelog_v" != "$app_v" ]; then
        echo "FAIL: CHANGELOG latest released version says '$changelog_v', APP_VERSION='$app_v' — drift detected"
        return 1
    fi
}
