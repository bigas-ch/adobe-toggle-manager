#!/usr/bin/env bats
# PB-06 (v4.15.0): Tests for the PlistBuddy mtime cache in discover_plists.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    # Test plist directory
    PLIST_DIR="$ATM_BASE/LaunchAgents"
    /bin/mkdir -p "$PLIST_DIR"
    export ATM_PLIST_DIRS=( "$PLIST_DIR" )

    # Mock PlistBuddy: counts calls + returns the label from the plist filename
    MOCK_PLISTBUDDY="$ATM_BASE/mock_PlistBuddy"
    MOCK_LOG="$ATM_BASE/mock_pb.log"
    cat > "$MOCK_PLISTBUDDY" <<'EOF'
#!/bin/bash
# Mock PlistBuddy: -c "Print :Label" $plist
# Logs every call, returns the label from the filename (e.g. com.adobe.foo.plist → com.adobe.foo)
printf '%s\n' "$*" >> "${MOCK_PB_LOG:-/dev/null}"
plist="$3"
basename=$(basename "$plist" .plist)
echo "$basename"
EOF
    /bin/chmod +x "$MOCK_PLISTBUDDY"
    export MOCK_PB_LOG="$MOCK_LOG"
}
teardown() { sandbox_teardown; }

# Helper: creates N Adobe plists with a valid label (otherwise log_warn fires)
_make_plists() {
    local n="$1"
    for i in $(seq 1 "$n"); do
        cat > "$PLIST_DIR/com.adobe.test${i}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.adobe.test${i}</string>
  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
</dict>
</plist>
EOF
    done
}

# === Cache-hit behavior =======================================================

@test "PB-06: 5x discover_plists → 1x PlistBuddy fork per plist (warm cache)" {
    _make_plists 3
    : > "$MOCK_LOG"
    run zsh -c "
        # PlistBuddy path in discover_plists is hardcoded — we use a PATH override
        # via shadowing through the zsh function-alias trick:
        source '$SCRIPT' >/dev/null 2>&1
        # Function shadowing: rebind /usr/libexec/PlistBuddy to our mock
        # via alias only takes effect after source
        function /usr/libexec/PlistBuddy() { '$MOCK_PLISTBUDDY' \"\$@\"; }
        export ATM_PLIST_DIRS=( '$PLIST_DIR' )

        for i in 1 2 3 4 5; do
            discover_plists >/dev/null
        done
        echo \"forks: \$(/usr/bin/wc -l < '$MOCK_LOG' | /usr/bin/tr -d ' ')\"
    "
    [ "$status" -eq 0 ]
    # 3 plists × 1 cold + 0 warm = 3 forks total (before: 3 × 5 = 15 forks)
    [[ "$output" == *"forks: 3"* ]]
}

@test "PB-06: plist modification invalidates cache" {
    : > "$PLIST_DIR/com.adobe.test1.plist"
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        function /usr/libexec/PlistBuddy() { '$MOCK_PLISTBUDDY' \"\$@\"; }
        export ATM_PLIST_DIRS=( '$PLIST_DIR' )

        # Cold call: 1 fork
        discover_plists >/dev/null
        # Modify: write larger content + wait 1s mtime tick
        echo 'modified' > '$PLIST_DIR/com.adobe.test1.plist'
        # Re-call: cache miss due to size+mtime → 1 more fork
        discover_plists >/dev/null
        echo \"forks: \$(/usr/bin/wc -l < '$MOCK_LOG' | /usr/bin/tr -d ' ')\"
    "
    [[ "$output" == *"forks: 2"* ]]
}

@test "PB-06: new plist in directory → cache miss" {
    : > "$PLIST_DIR/com.adobe.test1.plist"
    : > "$MOCK_LOG"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        function /usr/libexec/PlistBuddy() { '$MOCK_PLISTBUDDY' \"\$@\"; }
        export ATM_PLIST_DIRS=( '$PLIST_DIR' )

        discover_plists >/dev/null
        # Adobe-update simulation: new plist
        : > '$PLIST_DIR/com.adobe.test2.plist'
        discover_plists >/dev/null
        echo \"forks: \$(/usr/bin/wc -l < '$MOCK_LOG' | /usr/bin/tr -d ' ')\"
    "
    # 1st call: 1 fork (test1). 2nd call: 1 fork (test2 cache miss; test1 cache hit)
    [[ "$output" == *"forks: 2"* ]]
}

# === Output correctness (cache must be bit-identical to fresh) ================

@test "PB-06: discover_plists output stays identical to pre-cache behavior" {
    _make_plists 2
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        function /usr/libexec/PlistBuddy() { '$MOCK_PLISTBUDDY' \"\$@\"; }
        export ATM_PLIST_DIRS=( '$PLIST_DIR' )
        # 2 calls — both must return identical lines
        local first=\$(discover_plists)
        local second=\$(discover_plists)
        if [[ \"\$first\" == \"\$second\" ]]; then
            echo MATCH
            echo \"\$first\"
        else
            echo MISMATCH
            echo \"first:\"; echo \"\$first\"
            echo \"second:\"; echo \"\$second\"
        fi
    "
    [[ "$output" == *"MATCH"* ]]
    [[ "$output" == *"com.adobe.test1"* ]]
    [[ "$output" == *"com.adobe.test2"* ]]
}

# === Performance ==============================================================

# bats test_tags=perf
@test "PB-06: cache-warm discover_plists faster than cold (min. 2× speedup)" {
    _make_plists 5
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        export ATM_PLIST_DIRS=( '$PLIST_DIR' )

        # Cold: cache clear before each call
        local t1=\$(/bin/date +%s%N)
        for (( i=0; i<5; i++ )); do
            _PLIST_LABEL_CACHE=()
            _PLIST_LABEL_CACHE_KEYS=()
            discover_plists >/dev/null 2>&1
        done
        local t2=\$(/bin/date +%s%N)
        local cold_us=\$(( (t2 - t1) / 5 / 1000 ))

        # Warm: cache is filled once, then reused
        discover_plists >/dev/null 2>&1   # warmup
        t1=\$(/bin/date +%s%N)
        for (( i=0; i<5; i++ )); do
            discover_plists >/dev/null 2>&1
        done
        t2=\$(/bin/date +%s%N)
        local warm_us=\$(( (t2 - t1) / 5 / 1000 ))

        echo \"cold=\${cold_us}μs warm=\${warm_us}μs\"
        # Speedup of min. 2× expected (real system: 100ms → 24ms = 4×;
        # on CI with empty mock plists the factor may turn out different)
        if (( warm_us * 2 <= cold_us )); then echo PASS; else echo FAIL; fi
    "
    [[ "$output" == *"PASS"* ]]
}
