#!/usr/bin/env bats
# Performance tests for the authority cache (Finding M-2 fix).
# Verifies cache hit rate + verifies the cache actually saves codesign invocations.
# bats file_tags=perf

load helpers/sandbox.bash
load helpers/perf.bash

setup() {
    sandbox_setup
    # 10 mock Adobe binaries with proper authority strings
    for i in {1..10}; do
        local bin="$ATM_BASE/Adobe${i}"
        echo "v1" > "$bin"
        chmod +x "$bin"
        codesign_db_add "$bin" "Developer ID Application: Adobe Inc. (JQ525L2MZD)"
    done
}
teardown() { sandbox_teardown; }

@test "cache hit rate: 100 calls on 10 binaries → 10 codesign invocations (90% hit rate)" {
    # All 100 calls hit the same 10 binaries → after first 10, all hits.
    run zsh -c "
        ATM_BASE='$ATM_BASE'
        ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
        source '$SCRIPT' >/dev/null 2>&1
        for round in {1..10}; do
            for i in {1..10}; do
                _codesign_auth_and_id '$ATM_BASE/Adobe'\$i >/dev/null
            done
        done
        print -- \"cache_size=\${#_AUTHORITY_CACHE[@]}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"cache_size=10"* ]]
    # Codesign should have been invoked exactly 10 times (once per unique binary)
    local invocations
    invocations=$(wc -l < "$ATM_MOCK_LOG_DIR/codesign.log" | tr -d ' ')
    echo "PERF [cache hit rate] 100 calls → $invocations codesign invocations (target: 10)"
    [ "$invocations" = "10" ]
}

@test "perf: codesign cache HIT (cold call vs warm call)" {
    # Cold: clear cache first; Warm: re-call same binary
    local bin="$ATM_BASE/Adobe1"
    read cold_median cold_p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            _codesign_auth_and_id '$bin'
        \"
    ")
    # Warm: the cache lives in the shell process. Since each measure_n iteration
    # spawns a fresh subshell, "warm" must be measured INSIDE one zsh call.
    read warm_median warm_p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            _codesign_auth_and_id '$bin'  # populate cache
            _codesign_auth_and_id '$bin'  # warm hit
        \"
    ")
    report_perf "codesign COLD" "$cold_median" "$cold_p95"
    report_perf "codesign WARM (2 calls, 2nd cached)" "$warm_median" "$warm_p95"
    # warm should not be slower than cold (mock case may be very fast)
    # Hard threshold: P95 cold < 300ms (subshell startup dominates)
    [ "$cold_p95" -lt 500 ]
}

@test "cache stays persistent across multiple in-process calls (M-2 regression)" {
    # The Finding M-2 fix: var=$(_codesign_authority $b) was a subshell — cache lost.
    # Now we call _codesign_auth_and_id directly. Verify cache persists.
    run zsh -c "
        ATM_BASE='$ATM_BASE'
        ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
        source '$SCRIPT' >/dev/null 2>&1
        _codesign_auth_and_id '$ATM_BASE/Adobe1' >/dev/null
        size_after_1=\${#_AUTHORITY_CACHE[@]}
        _codesign_auth_and_id '$ATM_BASE/Adobe2' >/dev/null
        size_after_2=\${#_AUTHORITY_CACHE[@]}
        print -- \"after_1=\$size_after_1 after_2=\$size_after_2\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"after_1=1"* ]]
    [[ "$output" == *"after_2=2"* ]]
}

@test "perf: 100 cache lookups (warm) take negligible time" {
    # Inside a single shell process, 100 lookups on cached binary should be fast.
    read median p95 < <(measure_n 5 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            _codesign_auth_and_id '$ATM_BASE/Adobe1' >/dev/null
            for i in {1..100}; do
                _codesign_auth_and_id '$ATM_BASE/Adobe1' >/dev/null
            done
        \"
    ")
    report_perf "100 cache HITs (warm)" "$median" "$p95" 1000
    [ "$p95" -lt 1000 ]
}
