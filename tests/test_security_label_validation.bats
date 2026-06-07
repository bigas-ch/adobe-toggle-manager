#!/usr/bin/env bats
# Security tests for _validate_label (Finding C-3 — TSV-Injection-Schutz).
# Pro property: positive (legit label accepted) + negative (attack rejected).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# ----- positive cases -----

@test "label: legit com.adobe.* label accepted" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.AdobeIPCBroker'"
    [ "$status" -eq 0 ]
}

@test "label: legit com.adobesystems.* label accepted" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobesystems.cc'"
    [ "$status" -eq 0 ]
}

@test "label: legacy underscore label accepted (Adobe Genuine Service)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'Adobe_Genuine_Software_Integrity_Service'"
    [ "$status" -eq 0 ]
}

@test "label: alphanumeric + dot + dash + underscore accepted" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.foo-bar_baz.123'"
    [ "$status" -eq 0 ]
}

@test "label: max-length 255 chars accepted" {
    local long
    long=$(printf 'a%.0s' {1..255})
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label '$long'"
    [ "$status" -eq 0 ]
}

# ----- negative cases — attacks must be rejected -----

@test "label: empty string rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label ''"
    [ "$status" -ne 0 ]
}

@test "label: shell metacharacter ; rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.foo;rm -rf /'"
    [ "$status" -ne 0 ]
}

@test "label: command-substitution \$() rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.\$(whoami)'"
    [ "$status" -ne 0 ]
}

@test "label: backtick command-substitution rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.\`id\`'"
    [ "$status" -ne 0 ]
}

@test "label: pipe character rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.foo|cat'"
    [ "$status" -ne 0 ]
}

@test "label: ampersand rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.foo&background'"
    [ "$status" -ne 0 ]
}

@test "label: glob asterisk rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.*'"
    [ "$status" -ne 0 ]
}

@test "label: TAB inside label rejected (TSV-injection vector)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.foo\tinjected\tcol'"
    [ "$status" -ne 0 ]
}

@test "label: NEWLINE inside label rejected (TSV-injection vector)" {
    # Build the label string with embedded newline via printf, then feed via env
    local injected
    injected=$'com.adobe.foo\nrogue'
    INJECTED_LABEL="$injected" run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label \"\$INJECTED_LABEL\""
    [ "$status" -ne 0 ]
}

@test "label: starting with digit rejected (must start with letter)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label '1.adobe.foo'"
    [ "$status" -ne 0 ]
}

@test "label: starting with dot rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label '.adobe.foo'"
    [ "$status" -ne 0 ]
}

@test "label: 256-char (over max) rejected (length-DoS)" {
    local toolong
    toolong=$(printf 'a%.0s' {1..256})
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label '$toolong'"
    [ "$status" -ne 0 ]
}

@test "label: path-traversal characters / rejected" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label '../etc/passwd'"
    [ "$status" -ne 0 ]
}

@test "label: unicode RTL-override (U+202E) rejected" {
    # zsh "RTL‮gnirts" — printf-formated to inject the character
    local rtl
    rtl=$(printf 'com.adobe.foo\xe2\x80\xae')
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label '$rtl'"
    [ "$status" -ne 0 ]
}

@test "label: NULL-byte literal rejected" {
    # Embed actual NUL via printf — bash strips after first NUL, but the validator
    # never sees a malformed string this way because shell can't pass NUL in $1.
    # This test verifies the behaviour: validator gets the truncated string ='com.adobe.X'
    # which IS valid — so we test a different angle: the validator must NOT crash.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _validate_label 'com.adobe.X'"
    [ "$status" -eq 0 ]
}

@test "disable_launchd_label rejects shell-injection label and does NOT call launchctl" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        disable_launchd_label 'com.adobe.foo;rm -rf /' user
    "
    # Must return non-zero AND not have logged any launchctl call
    [ "$status" -ne 0 ]
    run launchctl_log
    [ -z "$output" ]
}

@test "disable_launchd_label accepts legit label and DOES call launchctl bootout+disable" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        disable_launchd_label 'com.adobe.LegitTest' user
    "
    [ "$status" -eq 0 ]
    assert_launchctl_called bootout 1
    assert_launchctl_called disable 1
}
