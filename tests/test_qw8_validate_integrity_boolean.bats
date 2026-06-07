#!/usr/bin/env bats
# QW-8: disabled_list_validate_integrity must return a BOOLEAN exit code
# (0 = clean, 1 = dirty) instead of the raw malformed-line COUNT. The old
# count-as-exit-code wraps >255 and makes any boolean caller misread count>0
# as a multi-valued status. The malformed count is exposed separately via the
# _DLIST_MALFORMED_COUNT global so callers that want the number can still read
# it — the function keeps stdout clean (it is called inline by init_state).
#
# bats test_tags=qw8,disabled_list

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
}
teardown() { sandbox_teardown; }

@test "QW-8: clean file returns 0 and reports count 0" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.ok	gui	2026-05-03T12:00:00Z	auto_blocked
com.adobe.legacy	gui	2026-05-03T12:00:00Z
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity
        echo \"rc=\$?\"
        echo \"global=\${_DLIST_MALFORMED_COUNT}\"
    "
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"global=0"* ]]
}

@test "QW-8: single malformed line returns 1" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.ok	gui	2026-05-03T12:00:00Z	auto_blocked
com.adobe.bad	gui	2026-05-03T12:00:00Z	auto_blocked	extra
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity
        echo \"rc=\$?\"
    "
    [[ "$output" == *"rc=1"* ]]
}

# Core QW-8 fix: count-as-exit-code returned 3 here (and wraps >255). The
# boolean contract must collapse any positive count to exactly 1.
@test "QW-8: multiple malformed lines still return exactly 1 (boolean, not count)" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.b1	gui	2026-05-03T12:00:00Z	auto_blocked	extra
com.adobe.b2	gui	2026-05-03T12:00:00Z	totally_invalid_state
com.adobe.b3	only_two_cols
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity
        echo \"rc=\$?\"
        echo \"global=\${_DLIST_MALFORMED_COUNT}\"
    "
    [[ "$output" == *"rc=1"* ]]
    # The actual count is still exposed for callers that want it.
    [[ "$output" == *"global=3"* ]]
}

# The function must NOT pollute stdout (init_state calls it inline) — the
# count lives only in the global. Verify stdout stays empty while the global
# carries the count.
@test "QW-8: stdout stays clean, count lives in the global" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.bad	gui	2026-05-03T12:00:00Z	auto_blocked	extra
EOF
    # Call the function directly (no $()-subshell) so the global survives.
    # Its stdout is redirected to a file to prove it stays empty.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity > '$ATM_BASE/stdout_capture' 2>/dev/null
        echo \"stdout=[\$(< '$ATM_BASE/stdout_capture')]\"
        echo \"global=\${_DLIST_MALFORMED_COUNT}\"
    "
    [[ "$output" == *"stdout=[]"* ]]
    [[ "$output" == *"global=1"* ]]
}

@test "QW-8: missing file is clean (returns 0, count 0)" {
    /bin/rm -f "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity
        echo \"rc=\$?\"
        echo \"global=\${_DLIST_MALFORMED_COUNT}\"
    "
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"global=0"* ]]
}
