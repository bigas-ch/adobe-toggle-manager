#!/usr/bin/env bats
# Extended security tests for the _launchctl wrapper + ATM_LAUNCHCTL_REAL_DENY guard.
# Beyond the smoke-test: verify the guard fires for all subcommands and that
# explicit non-com.adobe.* labels are not accidentally blocked.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "guard blocks 'bootout' with com.adobe.* arg on real launchctl" {
    sandbox_use_real_launchctl_bin
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl bootout 'gui/501/com.adobe.Foo'"
    [ "$status" -eq 99 ]
}

@test "guard blocks 'disable' with com.adobe.* arg on real launchctl" {
    sandbox_use_real_launchctl_bin
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl disable 'gui/501/com.adobe.Foo'"
    [ "$status" -eq 99 ]
}

@test "guard blocks 'enable' with com.adobe.* arg on real launchctl" {
    sandbox_use_real_launchctl_bin
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl enable 'gui/501/com.adobe.Reader'"
    [ "$status" -eq 99 ]
}

@test "guard blocks 'bootstrap' if any arg matches com.adobe.*" {
    sandbox_use_real_launchctl_bin
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl bootstrap 'gui/501' '/Library/LaunchAgents/com.adobe.X.plist'"
    [ "$status" -eq 99 ]
}

@test "guard does NOT block calls when ATM_LAUNCHCTL_BIN is the mock" {
    # Default sandbox uses the mock. Even with com.adobe.* arg, it should pass through.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl disable 'gui/501/com.adobe.Foo'"
    [ "$status" -eq 0 ]
    assert_launchctl_called disable 1
}

@test "guard does NOT block non-adobe labels even on real launchctl" {
    sandbox_use_real_launchctl_bin
    # 'print' on a non-existent label — real launchctl returns non-zero, but NOT 99
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _launchctl print 'gui/501/com.example.NotAdobe'"
    [ "$status" -ne 99 ]
}

@test "guard fires when ATM_LAUNCHCTL_REAL_DENY=1 is explicitly set + real bin" {
    sandbox_use_real_launchctl_bin
    ATM_LAUNCHCTL_REAL_DENY=1 run zsh -c "
        export ATM_LAUNCHCTL_BIN=/bin/launchctl
        export ATM_LAUNCHCTL_REAL_DENY=1
        source '$SCRIPT' >/dev/null 2>&1
        _launchctl disable 'gui/501/com.adobe.X'
    "
    [ "$status" -eq 99 ]
}

@test "guard does NOT fire when ATM_LAUNCHCTL_REAL_DENY=0 (default production mode)" {
    # In production mode, the wrapper passes through to real launchctl.
    # Calling 'print' on a non-existent gui-domain label returns non-zero
    # but NOT the guard's exit 99.
    run zsh -c "
        export ATM_LAUNCHCTL_BIN=/bin/launchctl
        export ATM_LAUNCHCTL_REAL_DENY=0
        source '$SCRIPT' >/dev/null 2>&1
        _launchctl print 'gui/501/com.adobe.NonExistentTest'
    "
    # Real launchctl returns whatever it returns (typically non-zero),
    # but never our specific guard code 99.
    [ "$status" -ne 99 ]
}

@test "production behaviour: with default env, _launchctl forwards 1:1 to /bin/launchctl" {
    # No ATM_LAUNCHCTL_BIN override, no DENY guard → real launchctl version output
    run zsh -c "
        unset ATM_LAUNCHCTL_BIN ATM_LAUNCHCTL_REAL_DENY
        source '$SCRIPT' >/dev/null 2>&1
        _launchctl version
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"launchd"* || "$output" == *"version"* ]]
}
