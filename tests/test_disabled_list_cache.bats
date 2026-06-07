#!/usr/bin/env bats
# PB-04 (v4.15.0): Tests for the disabled_list tick cache.
# Behavior must be bit-identical to pre-v4.15.0, only faster.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
    export ATM_DISABLED_FILE
}
teardown() { sandbox_teardown; }

# === Cache correctness ========================================================

@test "PB-04: get_state reads a 4-col entry correctly from cache" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.foo	gui	2026-05-04T00:00:00Z	user_allowed
com.adobe.bar	gui	2026-05-04T00:00:00Z	auto_blocked
com.adobe.baz	system	2026-05-04T00:00:00Z	user_blocked
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_get_state com.adobe.foo
        disabled_list_get_state com.adobe.bar
        disabled_list_get_state com.adobe.baz
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"user_allowed"* ]]
    [[ "$output" == *"auto_blocked"* ]]
    [[ "$output" == *"user_blocked"* ]]
}

@test "PB-04: get_state lazy-migrate 3-col → auto_blocked" {
    printf 'com.adobe.legacy\tgui\t2026-05-04T00:00:00Z\n' > "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_get_state com.adobe.legacy
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "auto_blocked" ]]
}

@test "PB-04: get_state non-existent label → return 1, no output" {
    : > "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_get_state com.adobe.nonexistent
        echo \"exit=\$?\"
    "
    [[ "$output" == *"exit=1"* ]]
}

@test "PB-04: get_state without a file → return 1" {
    [ ! -f "$ATM_DISABLED_FILE" ]
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_get_state com.adobe.foo
        echo \"exit=\$?\"
    "
    [[ "$output" == *"exit=1"* ]]
}

# === Cache invalidation =======================================================

@test "PB-04: cache invalidates after set_state (mtime+inode change via mv)" {
    printf 'com.adobe.foo\tgui\t2026-05-04T00:00:00Z\tauto_blocked\n' > "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # 1. Read: cached as auto_blocked
        echo \"before: \$(disabled_list_get_state com.adobe.foo)\"
        # 2. Modify: set_state writes → mtime+inode change
        disabled_list_set_state com.adobe.foo gui user_allowed >/dev/null
        # 3. Read: must be user_allowed (cache reload)
        echo \"after:  \$(disabled_list_get_state com.adobe.foo)\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"before: auto_blocked"* ]]
    [[ "$output" == *"after:  user_allowed"* ]]
}

@test "PB-04: cache invalidates on file delete" {
    printf 'com.adobe.foo\tgui\t2026-05-04T00:00:00Z\tuser_allowed\n' > "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        echo \"before: \$(disabled_list_get_state com.adobe.foo)\"
        /bin/rm -f \"\$ATM_DISABLED_FILE\"
        disabled_list_get_state com.adobe.foo
        echo \"exit=\$?\"
    "
    [[ "$output" == *"before: user_allowed"* ]]
    [[ "$output" == *"exit=1"* ]]
}

@test "PB-04: cache invalidates on add (size change, same second)" {
    : > "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # First population — cache empty
        disabled_list_get_state com.adobe.foo >/dev/null 2>&1; echo \"step1=\$?\"
        # add → size changes from 0 → >0, mtime possibly same second
        disabled_list_add com.adobe.foo gui >/dev/null
        echo \"step2: \$(disabled_list_get_state com.adobe.foo)\"
    "
    [[ "$output" == *"step1=1"* ]]
    [[ "$output" == *"step2: auto_blocked"* ]]
}

@test "PB-04: explicit _disabled_list_cache_invalidate works" {
    printf 'com.adobe.foo\tgui\t2026-05-04T00:00:00Z\tuser_allowed\n' > "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Populate cache
        disabled_list_get_state com.adobe.foo >/dev/null
        # Invalidate manually
        _disabled_list_cache_invalidate
        # Cache vars empty?
        echo \"key='\${_DLIST_CACHE_KEY}'\"
        echo \"size=\${#_DLIST_STATE_CACHE}\"
        # Re-read works (cache is reloaded)
        echo \"reload: \$(disabled_list_get_state com.adobe.foo)\"
    "
    [[ "$output" == *"key=''"* ]]
    [[ "$output" == *"size=0"* ]]
    [[ "$output" == *"reload: user_allowed"* ]]
}

# === is_user_allowed uses the cache directly ==================================

@test "PB-04: is_user_allowed directly cache-backed (no \$()-subshell overhead)" {
    printf 'com.adobe.foo\tgui\t2026-05-04T00:00:00Z\tuser_allowed\n' > "$ATM_DISABLED_FILE"
    printf 'com.adobe.bar\tgui\t2026-05-04T00:00:00Z\tauto_blocked\n' >> "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_is_user_allowed com.adobe.foo && echo 'foo: yes'
        disabled_list_is_user_allowed com.adobe.bar || echo 'bar: no'
        disabled_list_is_user_allowed com.adobe.nonexistent || echo 'none: no'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"foo: yes"* ]]
    [[ "$output" == *"bar: no"* ]]
    [[ "$output" == *"none: no"* ]]
}

# === Performance ==============================================================

# bats test_tags=perf
@test "PB-04: cache hit under 250μs (was ~4400μs, ≥15× speedup)" {
    # Generate 50 entries
    : > "$ATM_DISABLED_FILE"
    for i in {1..50}; do
        printf 'com.adobe.bench%d\tgui\t2026-05-04T00:00:00Z\tauto_blocked\n' "$i" >> "$ATM_DISABLED_FILE"
    done
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Warm cache
        disabled_list_get_state com.adobe.bench1 >/dev/null
        # Bench: 100× hit
        local t1=\$(/bin/date +%s%N)
        for (( i=0; i<100; i++ )); do
            disabled_list_get_state com.adobe.bench25 >/dev/null
        done
        local t2=\$(/bin/date +%s%N)
        local us_per_call=\$(( (t2 - t1) / 100 / 1000 ))
        echo \"avg=\${us_per_call}μs/call\"
        # Threshold: 250μs. Was: ~4400μs (grep+head fork per call).
        # M3 Max reality with the zstat builtin: ~100-200μs/call.
        # CI macos runner is ~3× slower → 250μs is safe.
        if (( us_per_call < 250 )); then
            echo PASS
        else
            echo FAIL
        fi
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

# === Multi-file switching (tests reset the cache) =============================

@test "PB-04: cache resets on ATM_DISABLED_FILE path change" {
    local file_a="$ATM_BASE/file_a.list"
    local file_b="$ATM_BASE/file_b.list"
    printf 'com.adobe.A\tgui\t2026-05-04T00:00:00Z\tuser_allowed\n' > "$file_a"
    printf 'com.adobe.B\tgui\t2026-05-04T00:00:00Z\tauto_blocked\n' > "$file_b"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Read from file A
        ATM_DISABLED_FILE='$file_a'
        echo \"A→A: \$(disabled_list_get_state com.adobe.A)\"
        # Switch to file B
        ATM_DISABLED_FILE='$file_b'
        echo \"B→A: \$(disabled_list_get_state com.adobe.A 2>/dev/null)exit=\$?\"
        echo \"B→B: \$(disabled_list_get_state com.adobe.B)\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"A→A: user_allowed"* ]]
    # com.adobe.A must no longer exist if the cache was reset correctly
    [[ "$output" == *"B→A: exit=1"* ]]
    [[ "$output" == *"B→B: auto_blocked"* ]]
}
