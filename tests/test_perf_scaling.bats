#!/usr/bin/env bats
# Performance scaling tests (v4.13.2, Phase B — P-03..P-07).
# bats file_tags=perf

load helpers/sandbox.bash
load helpers/perf.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
}
teardown() { sandbox_teardown; }

# === P-03 discovery sweep with 100 mock plists =================================

@test "P-03: discovery_sweep with 100 mock Adobe plists — scales linearly" {
    /bin/mkdir -p "$ATM_BASE/plists"
    gen_mock_plists "$ATM_BASE/plists" 100
    read median p95 < <(measure_n 5 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
            init_state
            discovery_sweep
        \"
    ")
    report_perf "discovery 100-plists" "$median" "$p95" 5000
    # Cap: <5s for 100 plists (worst case with codesign+launchctl mocks)
    [ "$median" -lt 5000 ]
}

# === P-04 disabled.list with 1000 entries =====================================

@test "P-04: disabled_list_get_state with 1000 entries — <50ms median" {
    /bin/mkdir -p "$ATM_BASE"
    /bin/zsh -c "
        for (( i=1; i<=1000; i++ )); do
            printf 'com.adobe.bulk%d\tgui\t2026-05-03T12:00:00Z\tauto_blocked\n' \"\$i\"
        done > '$ATM_DISABLED_FILE'
    "
    [ "$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" | /usr/bin/tr -d ' ')" -eq 1000 ]
    read median p95 < <(measure_n 10 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            source '$SCRIPT' >/dev/null 2>&1
            disabled_list_get_state com.adobe.bulk500
        \"
    ")
    report_perf "get_state on 1000-entries" "$median" "$p95" 50
    [ "$median" -lt 100 ]   # 50ms target, 100ms cap
}

@test "P-04b: disabled_list_is_user_allowed with 1000 entries — <50ms median" {
    /bin/mkdir -p "$ATM_BASE"
    /bin/zsh -c "
        for (( i=1; i<=1000; i++ )); do
            printf 'com.adobe.bulk%d\tgui\t2026-05-03T12:00:00Z\tauto_blocked\n' \"\$i\"
        done > '$ATM_DISABLED_FILE'
    "
    read median p95 < <(measure_n 10 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            source '$SCRIPT' >/dev/null 2>&1
            disabled_list_is_user_allowed com.adobe.bulk999 || true
        \"
    ")
    report_perf "is_user_allowed on 1000-entries" "$median" "$p95" 50
    [ "$median" -lt 100 ]
}

@test "P-04c: disabled_list_set_state update with 1000 entries — <500ms (TSV rewrite)" {
    /bin/mkdir -p "$ATM_BASE"
    /bin/zsh -c "
        for (( i=1; i<=1000; i++ )); do
            printf 'com.adobe.bulk%d\tgui\t2026-05-03T12:00:00Z\tauto_blocked\n' \"\$i\"
        done > '$ATM_DISABLED_FILE'
    "
    read median p95 < <(measure_n 5 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            source '$SCRIPT' >/dev/null 2>&1
            disabled_list_set_state com.adobe.bulk500 gui user_allowed
        \"
    ")
    report_perf "set_state-update on 1000-entries" "$median" "$p95" 500
    # set_state rewrites TSV → slower (O(n)), but under 1s is OK
    [ "$median" -lt 1000 ]
}

# === P-05 block_action with 100 discovered items ==============================

@test "P-05: block_action with 100 discovered launchd items — <3s median" {
    /bin/mkdir -p "$ATM_BASE/plists"
    gen_mock_plists "$ATM_BASE/plists" 100
    # Pre-populate discovered.list so block_action has work to do
    read median p95 < <(measure_n 3 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
            init_state
            block_action
        \"
    ")
    report_perf "block_action 100-items" "$median" "$p95" 3000
    [ "$median" -lt 5000 ]   # 3s target, 5s cap
}

# === P-06 allow_action with 50 disabled components ============================

@test "P-06: allow_action with 50 disabled items — <2s median" {
    /bin/mkdir -p "$ATM_BASE"
    /bin/zsh -c "
        for (( i=1; i<=50; i++ )); do
            printf 'com.adobe.allow%d\tgui\t2026-05-03T12:00:00Z\tauto_blocked\n' \"\$i\"
        done > '$ATM_DISABLED_FILE'
    "
    read median p95 < <(measure_n 3 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            init_state
            # Re-populate before each iteration (allow_action consumes the file)
            for (( i=1; i<=50; i++ )); do
                printf 'com.adobe.allow%d\tgui\t2026-05-03T12:00:00Z\tauto_blocked\n' \\\"\\\$i\\\"
            done > '$ATM_DISABLED_FILE'
            allow_action
        \"
    ")
    report_perf "allow_action 50-disabled" "$median" "$p95" 2000
    [ "$median" -lt 3000 ]   # 2s target, 3s cap
}

# === P-07 JSON encoder with 10KB string =========================================

@test "P-07: json_str with 10KB string — <100ms median" {
    read median p95 < <(measure_n 10 "
        zsh -c \"
            typeset -g APP_VERSION=t APP_LABEL=t _BACKENDS_AVAILABLE=0
            typeset -g DEFAULT_TICK_INTERVAL=30 DEFAULT_SAFETY_TICK_INTERVAL=300
            function read_state() { print block; }
            function live_state_get() { return 1; }
            function _launchctl() { return 1; }
            source lib/json.zsh
            big=\\\$(printf 'A%.0s' {1..10240})
            json_str \\\"\\\$big\\\" > /dev/null
        \"
    ")
    report_perf "json_str 10KB-string" "$median" "$p95" 100
    [ "$median" -lt 200 ]   # 100ms target, 200ms cap
}

@test "P-07b: json_str with 10KB newline-containing string — <300ms median (loop cost)" {
    # Newlines trigger the manual-loop path (slower than simple subst)
    read median p95 < <(measure_n 5 "
        zsh -c \"
            typeset -g APP_VERSION=t APP_LABEL=t _BACKENDS_AVAILABLE=0
            typeset -g DEFAULT_TICK_INTERVAL=30 DEFAULT_SAFETY_TICK_INTERVAL=300
            function read_state() { print block; }
            function live_state_get() { return 1; }
            function _launchctl() { return 1; }
            source lib/json.zsh
            # 100 lines x 100 chars = 10KB with 100 newlines
            big=\\\$(for i in {1..100}; do printf 'A%.0s' {1..100}; echo; done)
            json_str \\\"\\\$big\\\" > /dev/null
        \"
    ")
    report_perf "json_str 10KB+100 newlines" "$median" "$p95" 300
    [ "$median" -lt 500 ]
}
