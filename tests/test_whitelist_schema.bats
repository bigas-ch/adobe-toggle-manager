#!/usr/bin/env bats
# Tests for v4.8.0 disabled.list 4-column schema + lazy migration + state functions.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# Source disabled_list.zsh + dependencies in isolation.
_run_dlist() {
    /bin/zsh -c "
        emulate -L zsh
        setopt PIPE_FAIL
        export ATM_BASE='$ATM_BASE'
        typeset -g ATM_DISABLED_FILE=\"\$ATM_BASE/disabled.list\"
        typeset -g LAUNCHD_LABEL_REGEX='^[A-Za-z][A-Za-z0-9._-]{0,254}\$'
        function _validate_label() { [[ \"\$1\" =~ \$LAUNCHD_LABEL_REGEX ]]; }
        function log_warn() { echo \"WARN: \$*\" >&2; }
        source '$BATS_TEST_DIRNAME/../lib/disabled_list.zsh'
        $1
    "
}

@test "disabled_list_add: default state is auto_blocked" {
    run _run_dlist 'disabled_list_add com.adobe.test gui'
    [ "$status" -eq 0 ]
    local content
    content=$(cat "$ATM_BASE/disabled.list")
    [[ "$content" == *"auto_blocked"* ]]
    # 4 fields TAB-separated
    local cols
    cols=$(echo "$content" | /usr/bin/awk -F'\t' '{print NF}')
    [ "$cols" -eq 4 ]
}

@test "disabled_list_add: explicit user_blocked as 3rd argument" {
    run _run_dlist 'disabled_list_add com.adobe.test gui user_blocked'
    [ "$status" -eq 0 ]
    [[ "$(cat "$ATM_BASE/disabled.list")" == *"user_blocked"* ]]
}

@test "disabled_list_add: invalid state is rejected" {
    run _run_dlist 'disabled_list_add com.adobe.test gui invalid_state'
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid state"* ]]
}

@test "disabled_list_get_state: returns state correctly" {
    run _run_dlist 'disabled_list_add com.adobe.test gui user_allowed
disabled_list_get_state com.adobe.test'
    [ "$status" -eq 0 ]
    [[ "$output" == *"user_allowed"* ]]
}

@test "disabled_list_get_state: not present → exit 1" {
    run _run_dlist 'disabled_list_get_state com.adobe.unknown'
    [ "$status" -eq 1 ]
}

@test "Lazy migration: 3-col legacy entry → state=auto_blocked on read" {
    # Manually write a legacy 3-col entry
    printf 'com.adobe.legacy\tgui\t2026-05-03T12:00:00Z\n' > "$ATM_BASE/disabled.list"
    run _run_dlist 'disabled_list_get_state com.adobe.legacy'
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto_blocked"* ]]
}

@test "disabled_list_set_state: update existing entry" {
    run _run_dlist 'disabled_list_add com.adobe.test gui auto_blocked
disabled_list_set_state com.adobe.test gui user_allowed
disabled_list_get_state com.adobe.test'
    [ "$status" -eq 0 ]
    [[ "$output" == *"user_allowed"* ]]
    # File must NO LONGER contain an auto_blocked entry for com.adobe.test
    local count
    count=$(/usr/bin/grep -c "com.adobe.test" "$ATM_BASE/disabled.list")
    [ "$count" -eq 1 ]
}

@test "disabled_list_set_state: new entry is created when not present" {
    run _run_dlist 'disabled_list_set_state com.adobe.new gui user_allowed
disabled_list_get_state com.adobe.new'
    [ "$status" -eq 0 ]
    [[ "$output" == *"user_allowed"* ]]
}

@test "disabled_list_set_state: migration of a legacy 3-col entry on update" {
    # Mix: 1 legacy 3-col + 1 new 4-col entry
    printf 'com.adobe.legacy\tgui\t2026-05-03T12:00:00Z\n' > "$ATM_BASE/disabled.list"
    run _run_dlist 'disabled_list_add com.adobe.new gui auto_blocked
disabled_list_set_state com.adobe.legacy gui user_allowed
disabled_list_get_state com.adobe.legacy
disabled_list_get_state com.adobe.new'
    [ "$status" -eq 0 ]
    # Both states correct
    [[ "$output" == *"user_allowed"* ]]
    [[ "$output" == *"auto_blocked"* ]]
    # File must have all lines 4-col (legacy migrated on re-write)
    local non4col
    non4col=$(/usr/bin/awk -F'\t' 'NF != 4' "$ATM_BASE/disabled.list" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$non4col" -eq 0 ]
}

@test "disabled_list_is_user_allowed: true for user_allowed" {
    run _run_dlist 'disabled_list_add com.adobe.allow gui user_allowed
disabled_list_is_user_allowed com.adobe.allow && echo YES'
    [ "$status" -eq 0 ]
    [[ "$output" == *"YES"* ]]
}

@test "disabled_list_is_user_allowed: false for auto_blocked" {
    run _run_dlist 'disabled_list_add com.adobe.block gui auto_blocked
disabled_list_is_user_allowed com.adobe.block && echo YES || echo NO'
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO"* ]]
}

@test "disabled_list_is_user_allowed: false for user_blocked" {
    run _run_dlist 'disabled_list_add com.adobe.userblock gui user_blocked
disabled_list_is_user_allowed com.adobe.userblock && echo YES || echo NO'
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO"* ]]
}

@test "disabled_list_is_user_allowed: false when not present" {
    run _run_dlist 'disabled_list_is_user_allowed com.adobe.absent && echo YES || echo NO'
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO"* ]]
}

@test "disabled_list_is_user_allowed: lazy-migration legacy 3-col → auto_blocked → NOT user_allowed" {
    printf 'com.adobe.legacy\tgui\t2026-05-03T12:00:00Z\n' > "$ATM_BASE/disabled.list"
    run _run_dlist 'disabled_list_is_user_allowed com.adobe.legacy && echo YES || echo NO'
    [[ "$output" == *"NO"* ]]
}

@test "disabled_list_remove: deletes entry (4-col)" {
    run _run_dlist 'disabled_list_add com.adobe.test gui user_allowed
disabled_list_remove com.adobe.test
disabled_list_get_state com.adobe.test'
    [ "$status" -eq 1 ]
}
