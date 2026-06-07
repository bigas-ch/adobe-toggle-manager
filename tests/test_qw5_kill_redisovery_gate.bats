#!/usr/bin/env bats
# QW-5: kill_adobe_processes must NOT re-run live discover_processes when the
# TERM loop killed nothing (term_count==0). In steady state (no Adobe processes)
# the unconditional second discovery forked ps+awk + per-PID codesign for an
# empty KILL loop. Gate the re-discovery on term_count>0.

# bats test_tags=qw5,discovery,perf

load helpers/sandbox.bash

setup() {
    sandbox_setup
    # Adobe-signed fake binary so _validate_kill_target accepts the TERM target.
    export FAKE_BIN="$ATM_BASE/FakeAdobe"
    echo "v1" > "$FAKE_BIN"
    chmod +x "$FAKE_BIN"
    codesign_db_add "$FAKE_BIN" "Developer ID Application: Adobe Inc. (JQ525L2MZD)"
}
teardown() { sandbox_teardown; }

# The TERM loop reads from discovered.list (via _read_discovered_by_type). When
# it holds no process lines, nothing is TERM'd → term_count==0 → the KILL loop's
# live discover_processes must be skipped entirely.
@test "QW-5: kill_adobe_processes SKIPS second discover_processes when nothing TERM'd" {
    # discovered.list with ONLY a launchd line — zero process entries.
    printf 'launchd\tcom.adobe.X\t%s/x.plist\tgui\n' "$ATM_BASE" > "$ATM_BASE/discovered.list"

    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        ATM_DISCOVERED_FILE='$ATM_BASE/discovered.list'
        # Spy: every live discover_processes call appends one line.
        discover_processes() { print 'CALLED' >> '$ATM_BASE/disc_spy.log'; }
        kill_adobe_processes
    "
    [ "$status" -eq 0 ]
    # term_count==0 → the second (KILL-loop) discovery must NOT have run.
    [ ! -f "$ATM_BASE/disc_spy.log" ]
}

@test "QW-5: kill_adobe_processes STILL re-discovers when a process WAS TERM'd" {
    # A real, harmless background process we are allowed to TERM.
    /bin/sleep 30 &
    local victim_pid=$!

    printf 'process\tcom.adobe.X\tpid:%s\t%s\n' "$victim_pid" "$FAKE_BIN" \
        > "$ATM_BASE/discovered.list"

    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state
        ATM_DISCOVERED_FILE='$ATM_BASE/discovered.list'
        # Spy on the KILL-loop discovery; return empty so the KILL loop is a no-op.
        discover_processes() { print 'CALLED' >> '$ATM_BASE/disc_spy.log'; }
        kill_adobe_processes
    "
    kill -KILL "$victim_pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    # term_count==1 → second discovery MUST have run exactly once.
    [ -f "$ATM_BASE/disc_spy.log" ]
    local n
    n=$(wc -l < "$ATM_BASE/disc_spy.log" | tr -d ' ')
    [ "$n" = "1" ]
}
