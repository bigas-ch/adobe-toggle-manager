#!/usr/bin/env bats
# PB-05 (v4.15.0): Tests for the pluginkit TTL cache.
# Behavior must be bit-identical to pre-v4.15.0, just with fewer pluginkit forks.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    # Mock pluginkit binary that counts each call + returns fixed output
    MOCK_PLUGINKIT="$ATM_BASE/mock_pluginkit"
    MOCK_LOG="$ATM_BASE/mock_pluginkit.log"
    cat > "$MOCK_PLUGINKIT" <<'EOF'
#!/bin/bash
# Mock pluginkit: counts invocations, returns fixed Adobe output for -m -A -v
# printf instead of echo: avoids the bash-echo quirk where $1=-e is interpreted as a flag
printf '%s\n' "$*" >> "${MOCK_PLUGINKIT_LOG:-/dev/null}"
case "$1" in
    -m)
        # Simulate `pluginkit -m -A -v` output with 2 Adobe extensions + 1 non-adobe
        # %b interprets \t as a TAB char (vs %s which prints the literal string)
        printf '%b\n' \
            "+    com.adobe.accmac.ACCFinderSync(1.0)\tUUID-1\t2026-05-04\t/Applications/Adobe.app/Contents/PlugIns/ACCFinderSync.appex" \
            "-    com.adobe.foo.QuickLook(2.0)\tUUID-2\t2026-05-04\t/Applications/Adobe.app/Contents/PlugIns/foo.appex" \
            "+    com.apple.Maps.MapsHandoff(1.0)\tUUID-3\t2026-05-04\t/System/Library/Maps.appex"
        ;;
    -e)
        # Simulate -e ignore/use: success
        exit 0
        ;;
esac
EOF
    /bin/chmod +x "$MOCK_PLUGINKIT"
    export ATM_PLUGINKIT_BIN="$MOCK_PLUGINKIT"
    export MOCK_PLUGINKIT_LOG="$MOCK_LOG"
}
teardown() { sandbox_teardown; }

# === Cache hits dedupe forks ==================================================

@test "PB-05: 5x discover call → 1x pluginkit fork (cache hit on 4 calls)" {
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        for i in 1 2 3 4 5; do
            backend_dispatch pluginkit discover >/dev/null 2>&1
        done
        echo \"forks: \$(/usr/bin/grep -c '^-m' '$MOCK_LOG')\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"forks: 1"* ]]
}

@test "PB-05: discover + 3x is_blocked → only 1x pluginkit fork" {
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        backend_dispatch pluginkit discover >/dev/null 2>&1
        backend_dispatch pluginkit is_blocked appex com.adobe.accmac.ACCFinderSync user /path 2>/dev/null
        backend_dispatch pluginkit is_blocked appex com.adobe.foo.QuickLook user /path 2>/dev/null
        backend_dispatch pluginkit is_blocked appex com.adobe.accmac.ACCFinderSync user /path 2>/dev/null
        echo \"forks: \$(/usr/bin/grep -c '^-m' '$MOCK_LOG')\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"forks: 1"* ]]
}

# === Cache invalidation =======================================================

@test "PB-05: block invalidates cache → next discover makes a fresh fork" {
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # 1. discover (fork 1, populates cache)
        backend_dispatch pluginkit discover >/dev/null 2>&1
        # 2. block a '+' item (ACCFinderSync) → -e ignore is called → invalidate
        backend_dispatch pluginkit block appex com.adobe.accmac.ACCFinderSync user /path 2>/dev/null
        # 3. discover (should make fork 2, because the cache was invalidated)
        backend_dispatch pluginkit discover >/dev/null 2>&1
        echo \"forks: \$(/usr/bin/grep -c '^-m' '$MOCK_LOG')\"
        echo \"e-calls: \$(/usr/bin/grep -c '^-e' '$MOCK_LOG')\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"forks: 2"* ]]
    [[ "$output" == *"e-calls: 1"* ]]
}

@test "PB-05: block on an already-blocked item is a no-op (no -e call, no invalidate)" {
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        backend_dispatch pluginkit discover >/dev/null 2>&1
        # foo.QuickLook is already '-' (ignored) → block returns 1, no -e
        backend_dispatch pluginkit block appex com.adobe.foo.QuickLook user /path 2>/dev/null
        backend_dispatch pluginkit discover >/dev/null 2>&1
        echo \"forks: \$(/usr/bin/grep -c '^-m' '$MOCK_LOG')\"
        echo \"e-calls: \$(/usr/bin/grep -c '^-e' '$MOCK_LOG')\"
    "
    # 1 fork (no invalidate because block was a no-op), 0 -e calls
    [[ "$output" == *"forks: 1"* ]]
    [[ "$output" == *"e-calls: 0"* ]]
}

@test "PB-05: allow invalidates cache" {
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        backend_dispatch pluginkit discover >/dev/null 2>&1
        # allow (current state is '-' for foo.QuickLook → -e use is called → invalidate)
        backend_dispatch pluginkit allow appex com.adobe.foo.QuickLook user /path 2>/dev/null
        backend_dispatch pluginkit discover >/dev/null 2>&1
        echo \"forks: \$(/usr/bin/grep -c '^-m' '$MOCK_LOG')\"
    "
    [[ "$output" == *"forks: 2"* ]]
}

@test "PB-05: explicit _pluginkit_cache_invalidate forces a refresh" {
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        backend_dispatch pluginkit discover >/dev/null 2>&1
        _pluginkit_cache_invalidate
        backend_dispatch pluginkit discover >/dev/null 2>&1
        echo \"forks: \$(/usr/bin/grep -c '^-m' '$MOCK_LOG')\"
    "
    [[ "$output" == *"forks: 2"* ]]
}

# === Output correctness (cache must be bit-identical to live) ================

@test "PB-05: discover output filters Adobe items correctly" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        backend_dispatch pluginkit discover 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # Both Adobe items present + non-adobe filtered out
    [[ "$output" == *"com.adobe.accmac.ACCFinderSync"* ]]
    [[ "$output" == *"com.adobe.foo.QuickLook"* ]]
    [[ "$output" != *"com.apple.Maps"* ]]
    # Format: appex<TAB>id<TAB>user<TAB>path
    [[ "$output" == *"appex	com.adobe.accmac.ACCFinderSync	user	"* ]]
}

@test "PB-05: is_blocked reads the cache, returns the correct status" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        backend_dispatch pluginkit discover >/dev/null 2>&1
        # +-prefix = enabled (not blocked)
        backend_dispatch pluginkit is_blocked appex com.adobe.accmac.ACCFinderSync user /path
        echo \"plus=\$?\"
        # --prefix = ignored (blocked)
        backend_dispatch pluginkit is_blocked appex com.adobe.foo.QuickLook user /path
        echo \"minus=\$?\"
        # not present = unknown
        backend_dispatch pluginkit is_blocked appex com.adobe.nonexistent user /path
        echo \"unknown=\$?\"
    "
    [[ "$output" == *"plus=1"* ]]    # enabled = not blocked
    [[ "$output" == *"minus=0"* ]]   # ignored = blocked
    [[ "$output" == *"unknown=2"* ]] # not found
}

# === TTL behavior =============================================================

@test "PB-05: PLUGINKIT_CACHE_TTL is set readonly to 60" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        echo \"ttl=\${PLUGINKIT_CACHE_TTL}\"
    "
    [[ "$output" == *"ttl=60"* ]]
}
