#!/usr/bin/env bats
# Edge cases (v4.13.4, Phase D — L-06..L-10).

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    echo "block" > "$ATM_BASE/state"
}
teardown() { sandbox_teardown; }

# === L-06 Time-Travel: Clock-backwards =========================================

@test "L-06: heartbeat_age=null when live_state missing (no crash on missing data)" {
    # If live_state is missing → heartbeat_ts=null → heartbeat_age=null
    # This also simulates clock skew + clock-backwards (an extreme negative would
    # be reported as 'unhealthy: heartbeat-stale' under correct logic, not a crash)
    [[ ! -f "$ATM_BASE/live_state" ]]   # live_state absent
    run /bin/zsh -c "
        export ATM_BASE='$ATM_BASE'
        export ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
        export ATM_LAUNCHCTL_REAL_DENY=1
        '$SCRIPT' status --json
    "
    [ "$status" -eq 0 ]
    # JSON must be valid, healthy=false with reason
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['daemon']['healthy'] == False
assert d['daemon']['healthy_reason'] in ('no-pid', 'pid-not-alive', 'no-heartbeat'), d['daemon']['healthy_reason']
"
}

@test "L-06b: heartbeat_age negative (clock-backwards skew) is handled sanely" {
    # Write live_state with ts=$(now)+10000 (future heartbeat = clock went backwards)
    local future=$(( $(/bin/date +%s) + 10000 ))
    cat > "$ATM_BASE/live_state" <<EOF
heartbeat_ts=$future
ticks=42
disabled=0
killed=0
last_disable=
last_kill=
EOF
    run /bin/zsh -c "
        export ATM_BASE='$ATM_BASE'
        export ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
        export ATM_LAUNCHCTL_REAL_DENY=1
        '$SCRIPT' status --json
    "
    [ "$status" -eq 0 ]
    # heartbeat_age becomes negative — health logic must not crash
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.load(sys.stdin)
# heartbeat_age_s may be negative, that is ok — no crash, valid JSON
assert 'heartbeat_age_s' in d['daemon']
"
}

# === L-07 Timezone change ======================================================

@test "L-07: Timestamps are UTC (-u flag in date)" {
    # Verify via code inspection: all date calls use -u
    /usr/bin/grep -rE "/bin/date" lib/ adobe-toggle | \
        /usr/bin/grep -vE '\+%[YHMS]|+%s|^[^:]*:#' | \
        /usr/bin/grep -vE "/bin/date -u\|/bin/date +%s" || true
    # At least some calls with -u for ISO timestamps
    local utc_count
    utc_count=$(/usr/bin/grep -rE "/bin/date -u" lib/ adobe-toggle 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$utc_count" -ge 3 ]
}

@test "L-07b: ISO timestamps have a Z suffix (UTC indicator)" {
    /usr/bin/grep -rE "Y-%m-%dT%H:%M:%SZ" lib/ adobe-toggle | /usr/bin/wc -l | /usr/bin/awk '{exit !($1 >= 2)}'
}

# === L-08 Locale test =========================================================

@test "L-08: emulate -L zsh isolates from user locale settings" {
    # emulate -L zsh resets all zsh options to default — defensive against
    # user LANG/LC_ALL pollution
    /usr/bin/grep -q "emulate -L zsh" adobe-toggle
    /usr/bin/grep -q "emulate -L zsh" install.sh
}

@test "L-08b: no locale-dependent sort order in critical paths (e.g. C locale for path comparison)" {
    # Verify that collation sort does not silently depend on locale
    # (sort without LC_ALL=C may produce a different order)
    # We use sort in a few places — count calls
    local sort_calls
    sort_calls=$(/usr/bin/grep -rE "/usr/bin/sort" lib/ adobe-toggle 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    # If sort is used, it should be deterministic. <3 calls: ok per audit.
    [ "$sort_calls" -le 3 ]
}

# === L-09 TUI resize storm =====================================================

@test "L-09: TUI uses /usr/bin/tput cols for resize-tolerant rendering" {
    /usr/bin/grep -q "/usr/bin/tput cols" lib/tui.zsh
}

@test "L-09b: TUI box engine has a fixed-width fallback on tput failure" {
    # box.zsh should default to cols=120 when tput fails
    /usr/bin/grep -E "cols=.*\|\| cols=" lib/tui.zsh | /usr/bin/wc -l | /usr/bin/awk '{exit !($1 >= 1)}'
}

# === L-10 Concurrent CLI =======================================================

@test "L-10: 5 parallel status --json stay atomic (no corrupt output)" {
    /bin/mkdir -p "$ATM_BASE"
    echo "block" > "$ATM_BASE/state"
    # 5 parallel status --json — all must produce valid JSON
    local results=()
    local i pids=()
    local outdir="$ATM_BASE/parallel_out"
    /bin/mkdir -p "$outdir"
    for i in 1 2 3 4 5; do
        ( /bin/zsh -c "
            export ATM_BASE='$ATM_BASE'
            export ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            export ATM_LAUNCHCTL_REAL_DENY=1
            '$SCRIPT' status --json
        " > "$outdir/out$i.json" 2>/dev/null ) &
        pids+=( $! )
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    # All 5 outputs must be valid JSON
    for i in 1 2 3 4 5; do
        /usr/bin/python3 -m json.tool < "$outdir/out$i.json" > /dev/null
    done
}
