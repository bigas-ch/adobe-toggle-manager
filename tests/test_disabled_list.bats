#!/usr/bin/env bats
# Unit tests for disabled-list I/O

setup() {
    export ATM_BASE="$(mktemp -d)"
    SCRIPT="$BATS_TEST_DIRNAME/../adobe-toggle"
}

teardown() {
    rm -rf "$ATM_BASE"
}

@test "disabled_list_add then read returns the entry" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_add com.adobe.AdobeIPCBroker user; disabled_list_read"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.AdobeIPCBroker"* ]]
    [[ "$output" == *"user"* ]]
}

@test "disabled_list_add is idempotent" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_add com.adobe.X user; disabled_list_add com.adobe.X user; wc -l < \"\$ATM_DISABLED_FILE\""
    [ "$status" -eq 0 ]
    [ "$(echo $output | tr -d ' ')" = "1" ]
}

@test "disabled_list_remove deletes only the matching label" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_add com.adobe.A user; disabled_list_add com.adobe.B user; disabled_list_remove com.adobe.A; disabled_list_read"
    [ "$status" -eq 0 ]
    [[ "$output" != *"com.adobe.A"$'\t'* ]]
    [[ "$output" == *"com.adobe.B"* ]]
}

@test "disabled_list_clear empties the file" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_add com.adobe.A user; disabled_list_clear; wc -l < \"\$ATM_DISABLED_FILE\""
    [ "$status" -eq 0 ]
    [ "$(echo $output | tr -d ' ')" = "0" ]
}

@test "disabled_list_add rejects empty label" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_add '' user"
    [ "$status" -ne 0 ]
}

@test "disabled_list_read returns nothing when file does not exist" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; init_state; disabled_list_read"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
