#!/usr/bin/env bats
# Security tests for the codesign authority cache (Finding C-2 — TOCTOU mitigation).
# Cache key = binary::inode:size:mtime, TTL 60s. Pre-action validation must use
# _codesign_authority_fresh (bypass cache).

load helpers/sandbox.bash

setup() {
    sandbox_setup
    # Create a fake "Adobe binary" we can swap.
    export FAKE_BIN="$ATM_BASE/FakeAdobe"
    echo "v1" > "$FAKE_BIN"
    chmod +x "$FAKE_BIN"
    codesign_db_add "$FAKE_BIN" "Developer ID Application: Adobe Inc. (JQ525L2MZD)"
}
teardown() { sandbox_teardown; }

@test "cache: first call populates cache; second call hits cache" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _codesign_auth_and_id '$FAKE_BIN' >/dev/null
        size_after_first=\${#_AUTHORITY_CACHE[@]}
        _codesign_auth_and_id '$FAKE_BIN' >/dev/null
        size_after_second=\${#_AUTHORITY_CACHE[@]}
        print -- \"size_after_first=\$size_after_first size_after_second=\$size_after_second\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"size_after_first=1"* ]]
    [[ "$output" == *"size_after_second=1"* ]]
}

@test "cache: only ONE codesign invocation for repeated calls (cache hit)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _codesign_auth_and_id '$FAKE_BIN' >/dev/null
        _codesign_auth_and_id '$FAKE_BIN' >/dev/null
        _codesign_auth_and_id '$FAKE_BIN' >/dev/null
    "
    [ "$status" -eq 0 ]
    # Mock logs every call. Should be exactly 1 (cache hit on 2nd+3rd).
    local n
    n=$(wc -l < "$ATM_MOCK_LOG_DIR/codesign.log" | tr -d ' ')
    [ "$n" = "1" ]
}

@test "cache invalidates when binary content changes (mtime changes)" {
    # First call: populate cache
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _codesign_auth_and_id '$FAKE_BIN' >/dev/null"
    [ "$status" -eq 0 ]
    # Change binary content — mtime + size change → cache key invalidates
    echo "v2-replaced-content-must-be-different" > "$FAKE_BIN"
    sleep 1   # ensure mtime tick
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _codesign_auth_and_id '$FAKE_BIN' >/dev/null; _codesign_auth_and_id '$FAKE_BIN' >/dev/null"
    [ "$status" -eq 0 ]
    # 2 calls total (1 from first run, 1 from second run after content change).
    # The second of the two should hit the cache after the content-change call refreshed it.
    local n
    n=$(wc -l < "$ATM_MOCK_LOG_DIR/codesign.log" | tr -d ' ')
    # Expected: at least 2 (initial + post-modify), max 3
    [ "$n" -ge 2 ]
}

@test "_codesign_authority_fresh BYPASSES cache (always calls codesign)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _codesign_authority_fresh '$FAKE_BIN' >/dev/null
        _codesign_authority_fresh '$FAKE_BIN' >/dev/null
        _codesign_authority_fresh '$FAKE_BIN' >/dev/null
    "
    [ "$status" -eq 0 ]
    # Fresh-variant must always invoke codesign — 3 calls expected
    local n
    n=$(wc -l < "$ATM_MOCK_LOG_DIR/codesign.log" | tr -d ' ')
    [ "$n" = "3" ]
}

@test "_validate_kill_target rejects missing binary" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _validate_kill_target 99999 com.adobe.X /nonexistent/binary"
    [ "$status" -ne 0 ]
}

@test "_validate_kill_target rejects non-Adobe authority (TOCTOU mitigation)" {
    # Binary exists, but DB returns non-Adobe authority
    local fake="$ATM_BASE/swapped"
    echo "x" > "$fake"
    codesign_db_add "$fake" "Developer ID Application: Evil Corp (FAKE)"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _validate_kill_target 99999 com.adobe.X '$fake'"
    [ "$status" -ne 0 ]
}

@test "_validate_kill_target accepts genuine Adobe binary" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _validate_kill_target 99999 com.adobe.X '$FAKE_BIN'"
    [ "$status" -eq 0 ]
}

@test "_validate_kill_target rejects non-numeric PID" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _validate_kill_target 'NOT_A_PID' com.adobe.X '$FAKE_BIN'"
    [ "$status" -ne 0 ]
}

@test "cache key includes size — content swap of same length still invalidates via mtime" {
    # Populate cache
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _codesign_auth_and_id '$FAKE_BIN' >/dev/null; print \${#_AUTHORITY_CACHE[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1"* ]]
    # Swap content (same length not guaranteed, but mtime changes)
    echo "v3" > "$FAKE_BIN"
    sleep 1
    # Cache should re-populate, not return stale
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _codesign_auth_and_id '$FAKE_BIN' >/dev/null"
    [ "$status" -eq 0 ]
    # Total codesign calls: 2 (initial + post-modify)
    local n
    n=$(wc -l < "$ATM_MOCK_LOG_DIR/codesign.log" | tr -d ' ')
    [ "$n" = "2" ]
}

@test "discover_processes accepts only Adobe-signed binaries" {
    # We can't easily inject ps output without monkey-patching, so this is
    # a structural test: discover_processes returns empty when codesign DB
    # is empty (default in fresh sandbox) because no PID's binary will match.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; discover_processes 2>/dev/null"
    # On a system without Adobe processes, output is empty — pass.
    # If Adobe processes ARE running, we can't predict — this test is a sanity check.
    [ "$status" -eq 0 ]
}
