#!/usr/bin/env bats
# v4.14.0 Phase α code optimizations — tests for the 4 implemented items.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
    ATM_AUTHORITY_CACHE_FILE="$ATM_BASE/authority_cache.tsv"
    ATM_WATCHER_HASH_FILE="$ATM_BASE/atm-watcher.sha256"
}
teardown() { sandbox_teardown; }

# === S-07 disabled.list schema validation ====================================

@test "S-07: validate_integrity detects malformed line (5 cols)" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.ok	gui	2026-05-03T12:00:00Z	auto_blocked
com.adobe.bad	gui	2026-05-03T12:00:00Z	auto_blocked	extra_col
com.adobe.also_ok	system	2026-05-03T12:00:00Z	user_allowed
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity
        echo \"exit=\$?\"
    "
    [[ "$output" == *"exit=1"* ]]   # 1 malformed line → return code 1
    # log_warn writes to the ndjson file (not stderr) → read the log file
    local today=$(date +%Y-%m-%d)
    /usr/bin/grep -q "malformed" "$ATM_BASE/logs/adobe-toggle.${today}.ndjson"
}

@test "S-07b: validate_integrity accepts mixed 3-col + 4-col legacy" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.legacy	gui	2026-05-03T12:00:00Z
com.adobe.new	gui	2026-05-03T12:00:00Z	user_allowed
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity 2>&1
        echo \"exit=\$?\"
    "
    [[ "$output" == *"exit=0"* ]]   # all clean
}

@test "S-07c: validate_integrity detects invalid state value" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.evil	gui	2026-05-03T12:00:00Z	totally_invalid_state
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_validate_integrity
        echo \"exit=\$?\"
    "
    [[ "$output" == *"exit=1"* ]]
    local today=$(date +%Y-%m-%d)
    /usr/bin/grep -q "invalid state" "$ATM_BASE/logs/adobe-toggle.${today}.ndjson"
}

@test "S-07d: init_state calls validate_integrity automatically" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.bad	gui	two	three	four	five
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        init_state 2>&1
        # Look for WARN in the log
        cat \"\$ATM_LOGS_DIR/adobe-toggle.\$(/bin/date +%Y-%m-%d).ndjson\" 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # A WARN about the malformed line must be present in the log
    [[ "$output" == *"malformed"* ]] || [[ "$output" == *"integrity-check"* ]]
}

# === S-02 authority-cache TTL cleanup =========================================

@test "S-02: _authority_cache_cleanup_expired removes expired entries" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Inject 2 entries: 1 fresh (ts=now), 1 expired (ts=now-3600)
        local now=\$(/bin/date +%s)
        local stale_ts=\$(( now - 3600 ))
        _AUTHORITY_CACHE[fresh_key]=\"auth1\\tid1|\${now}\"
        _AUTHORITY_CACHE[stale_key]=\"auth2\\tid2|\${stale_ts}\"
        echo \"before: \${#_AUTHORITY_CACHE}\"
        _authority_cache_cleanup_expired
        echo \"after: \${#_AUTHORITY_CACHE}\"
        # Fresh must still be present
        [[ -n \"\${_AUTHORITY_CACHE[fresh_key]+_}\" ]] && echo 'fresh-kept'
        # Stale must be gone
        [[ -z \"\${_AUTHORITY_CACHE[stale_key]+_}\" ]] && echo 'stale-removed'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"before: 2"* ]]
    [[ "$output" == *"after: 1"* ]]
    [[ "$output" == *"fresh-kept"* ]]
    [[ "$output" == *"stale-removed"* ]]
}

# === S-01 watcher file-hash pinning ===========================================

@test "S-01: _watcher_validate_swift_hash trust-on-first-use writes pin" {
    # Setup: fake .swift file
    local fake_src="$ATM_BASE/atm-watcher.swift"
    echo "// fake swift content" > "$fake_src"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCHER_SWIFT_SRC='$fake_src'
        ATM_WATCHER_HASH_FILE='$ATM_WATCHER_HASH_FILE'
        _watcher_validate_swift_hash && echo 'OK'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    # Hash file was written
    [ -f "$ATM_WATCHER_HASH_FILE" ]
    # Hash matches expected SHA-256 of "// fake swift content\n"
    local expected
    expected=$(/usr/bin/shasum -a 256 "$fake_src" | /usr/bin/awk '{print $1}')
    local pinned
    read -r pinned < "$ATM_WATCHER_HASH_FILE"
    [ "$pinned" = "$expected" ]
}

@test "S-01b: _watcher_validate_swift_hash detect tampering after pin" {
    local fake_src="$ATM_BASE/atm-watcher.swift"
    echo "// original content" > "$fake_src"
    # First call: pin
    /bin/zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCHER_SWIFT_SRC='$fake_src'
        ATM_WATCHER_HASH_FILE='$ATM_WATCHER_HASH_FILE'
        _watcher_validate_swift_hash
    "
    # Tamper with the file
    echo "// MALICIOUS content" > "$fake_src"
    # Second call must detect mismatch
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCHER_SWIFT_SRC='$fake_src'
        ATM_WATCHER_HASH_FILE='$ATM_WATCHER_HASH_FILE'
        _watcher_validate_swift_hash && echo 'OK' || echo 'MISMATCH'
    "
    [[ "$output" == *"MISMATCH"* ]]
}

@test "S-01c: ATM_WATCHER_SKIP_HASH=1 override allows mismatch (emergency)" {
    local fake_src="$ATM_BASE/atm-watcher.swift"
    echo "// original" > "$fake_src"
    /bin/zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCHER_SWIFT_SRC='$fake_src'
        ATM_WATCHER_HASH_FILE='$ATM_WATCHER_HASH_FILE'
        _watcher_validate_swift_hash
    "
    echo "// tampered" > "$fake_src"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_WATCHER_SWIFT_SRC='$fake_src'
        ATM_WATCHER_HASH_FILE='$ATM_WATCHER_HASH_FILE'
        ATM_WATCHER_SKIP_HASH=1 _watcher_validate_swift_hash && echo 'BYPASSED'
    "
    [[ "$output" == *"BYPASSED"* ]]
}

# === P-01 authority-cache persistence =========================================

@test "P-01: _authority_cache_save writes cache as TSV" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_AUTHORITY_CACHE_FILE='$ATM_AUTHORITY_CACHE_FILE'
        local now=\$(/bin/date +%s)
        _AUTHORITY_CACHE[/path/binary]=\"Adobe Inc.\\tcom.adobe.app|\${now}\"
        _authority_cache_save
        ls -la '$ATM_AUTHORITY_CACHE_FILE'
    "
    [ "$status" -eq 0 ]
    [ -f "$ATM_AUTHORITY_CACHE_FILE" ]
    # File contains the key + value
    /usr/bin/grep -q "/path/binary" "$ATM_AUTHORITY_CACHE_FILE"
}

@test "P-01b: _authority_cache_load takes over fresh entries, skips expired" {
    # Write a file with 1 fresh + 1 expired
    local now=$(/bin/date +%s)
    local stale=$(( now - 3600 ))
    cat > "$ATM_AUTHORITY_CACHE_FILE" <<EOF
fresh_key	auth1	id1|${now}
stale_key	auth2	id2|${stale}
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_AUTHORITY_CACHE_FILE='$ATM_AUTHORITY_CACHE_FILE'
        _authority_cache_load
        echo \"loaded=\${#_AUTHORITY_CACHE}\"
        [[ -n \"\${_AUTHORITY_CACHE[fresh_key]+_}\" ]] && echo 'fresh-loaded'
        [[ -z \"\${_AUTHORITY_CACHE[stale_key]+_}\" ]] && echo 'stale-skipped'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"loaded=1"* ]]
    [[ "$output" == *"fresh-loaded"* ]]
    [[ "$output" == *"stale-skipped"* ]]
}

@test "P-01c: roundtrip save → load preserves cache content" {
    /bin/zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_AUTHORITY_CACHE_FILE='$ATM_AUTHORITY_CACHE_FILE'
        local now=\$(/bin/date +%s)
        _AUTHORITY_CACHE[key1]=\"valA\\tidA|\${now}\"
        _AUTHORITY_CACHE[key2]=\"valB\\tidB|\${now}\"
        _authority_cache_save
    "
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_AUTHORITY_CACHE_FILE='$ATM_AUTHORITY_CACHE_FILE'
        _authority_cache_load
        echo \"size=\${#_AUTHORITY_CACHE}\"
    "
    [[ "$output" == *"size=2"* ]]
}

@test "P-01d: empty cache save is no-op" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        ATM_AUTHORITY_CACHE_FILE='$ATM_AUTHORITY_CACHE_FILE'
        _AUTHORITY_CACHE=()
        _authority_cache_save
    "
    [ "$status" -eq 0 ]
    # No file written because the cache was empty
    [ ! -f "$ATM_AUTHORITY_CACHE_FILE" ]
}
