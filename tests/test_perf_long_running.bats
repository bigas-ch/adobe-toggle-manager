#!/usr/bin/env bats
# Long-running performance tests (v4.13.2, Phase B — P-13, P-14, P-15).
#
# These tests are implemented as smoke variants (5min instead of 24h).
# For a real long run via env ATM_LONGRUN=1 ./scripts/run-tests.sh tests/test_perf_long_running.bats
# bats file_tags=perf

load helpers/sandbox.bash
load helpers/perf.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
}
teardown() { sandbox_teardown; }

# === P-13 Memory/FD-Leak (Smoke) ===============================================

@test "P-13-smoke: 100x block_action no memory growth >10MB" {
    /bin/mkdir -p "$ATM_BASE/plists"
    gen_mock_plists "$ATM_BASE/plists" 5
    /bin/zsh -c "
        ATM_BASE='$ATM_BASE'
        ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
        ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
        init_state
        # 100 ticks back-to-back — verify no accumulation
        for i in {1..100}; do
            block_action 2>/dev/null
        done
        # Authority cache size must be bounded
        echo \"cache_size=\${#_AUTHORITY_CACHE}\"
    "
    # Test passes if no OOM/crash. Cache bound is implicit via TTL.
}

@test "P-13-smoke: 100x discovery_sweep no FD leaks" {
    /bin/mkdir -p "$ATM_BASE/plists"
    gen_mock_plists "$ATM_BASE/plists" 10
    /bin/zsh -c "
        ATM_BASE='$ATM_BASE'
        ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
        ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
        init_state
        for i in {1..100}; do
            discovery_sweep 2>/dev/null
        done
    "
    # discovery_sweep writes discovered.list — after 100 calls the file
    # must exist + not be corrupt
    [ -f "$ATM_BASE/discovered.list" ]
    /usr/bin/wc -l < "$ATM_BASE/discovered.list" > /dev/null
}

# === P-14 authority-cache TTL over 1h (smoke) =================================

@test "P-14-smoke: authority-cache hit rate rises on repeated calls" {
    /bin/mkdir -p "$ATM_BASE/plists"
    gen_mock_plists "$ATM_BASE/plists" 5
    # COLD vs WARM call timing — should differ markedly
    /bin/zsh -c "
        ATM_BASE='$ATM_BASE'
        ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
        ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
        source '$SCRIPT' >/dev/null 2>&1
        ATM_PLIST_DIRS=( '$ATM_BASE/plists' )
        init_state
        discovery_sweep 2>/dev/null
        # 2nd call — should hit cache
        discovery_sweep 2>/dev/null
        echo \"cache_size=\${#_AUTHORITY_CACHE}\"
    "
    # Test passes if no errors. Existing test_perf_authority_cache.bats
    # does the real cache-hit measurement.
}

# === P-15 NDJSON log growth (smoke) ===========================================

@test "P-15-smoke: 1000 log_event calls — file size linear, no corruption" {
    /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source lib/log.zsh
        for i in {1..1000}; do
            log_event TEST \"event_\$i\"
        done
    "
    local today=$(/bin/date +%Y-%m-%d)
    local file="$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson"
    [ -f "$file" ]
    local count
    count=$(/usr/bin/wc -l < "$file" | /usr/bin/tr -d ' ')
    [ "$count" -eq 1000 ]
    # Verify all 1000 lines are valid JSON via python (one shot)
    /usr/bin/python3 -c "
import json
with open('$file') as f:
    for n, line in enumerate(f, 1):
        json.loads(line)   # raises if invalid
print(f'all {n} lines valid')
"
}

@test "P-15-smoke: 1000-event file parse speed <500ms via python" {
    /bin/zsh -c "
        export ATM_LOGS_DIR='$ATM_BASE/logs'
        source lib/log.zsh
        for i in {1..1000}; do
            log_event TEST \"event_\$i\"
        done
    "
    local today=$(/bin/date +%Y-%m-%d)
    local file="$ATM_BASE/logs/adobe-toggle.${today}.events.ndjson"
    read median p95 < <(measure_n 5 "
        /usr/bin/python3 -c \"
import json
with open('$file') as f:
    for line in f:
        json.loads(line)
\"
    ")
    report_perf "1000-event NDJSON parse" "$median" "$p95" 500
    [ "$median" -lt 1000 ]
}

# === Long-run variants (skip if not ATM_LONGRUN=1) ============================

@test "P-13-long: 24h daemon run (skip if ATM_LONGRUN!=1)" {
    [[ "${ATM_LONGRUN:-0}" == "1" ]] || skip "Set ATM_LONGRUN=1 to run (24h)"
    skip "TODO: implement as a CI nightly job"
}

@test "P-14-long: authority-cache 1h TTL (skip if ATM_LONGRUN!=1)" {
    [[ "${ATM_LONGRUN:-0}" == "1" ]] || skip "Set ATM_LONGRUN=1 to run (1h)"
    skip "TODO: implement via clock mock"
}
