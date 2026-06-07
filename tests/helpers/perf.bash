#!/usr/bin/env bash
# Performance measurement helpers for Adobe Toggle bats tests.
# Methodology: N repetitions → report Median + P95 (NEVER mean, which is
# heavily skewed by outliers when the system has background load).

# Run a command N times, measure each in milliseconds, return median and P95.
# Usage: read median p95 < <(measure_n 20 'my_command args')
# Note: the command must be self-contained shell snippet (eval'd).
measure_n() {
    # Avoid 'local' — it triggers the zsh quirk where redeclaring an
    # already-set variable emits 'var=value' on stdout. See v3.2.1 lesson.
    # Use unique-prefixed names instead.
    __mn_n="$1"
    __mn_cmd="$2"
    __mn_samples=()
    __mn_i=1
    while [ "$__mn_i" -le "$__mn_n" ]; do
        # zsh's $EPOCHREALTIME → seconds.microseconds. Spawn one zsh per
        # measurement so we don't pay python3 startup cost.
        __mn_elapsed=$(/bin/zsh -c "
            zmodload zsh/datetime
            __t_start=\$EPOCHREALTIME
            { $__mn_cmd ; } >/dev/null 2>&1
            __t_end=\$EPOCHREALTIME
            printf '%.0f\n' \$(( ( __t_end - __t_start ) * 1000 ))
        " 2>/dev/null)
        [[ "$__mn_elapsed" =~ ^[0-9]+$ ]] || __mn_elapsed=0
        __mn_samples+=( "$__mn_elapsed" )
        __mn_i=$((__mn_i + 1))
    done
    __mn_sorted=$(printf '%s\n' "${__mn_samples[@]}" | sort -n)
    __mn_median=$(echo "$__mn_sorted" | awk -v n="$__mn_n" 'NR==int((n+1)/2)')
    __mn_p95=$(echo "$__mn_sorted" | awk -v n="$__mn_n" 'BEGIN{p=int(n*0.95); if(p<1)p=1} NR==p')
    echo "$__mn_median $__mn_p95"
}

# Pretty-print perf result for bats stdout.
# Usage: report_perf "label" $median $p95 [$threshold_ms]
report_perf() {
    local label="$1" median="$2" p95="$3" threshold="${4:-}"
    local extra=""
    [[ -n "$threshold" ]] && extra=" (threshold ${threshold}ms)"
    echo "PERF [$label] median=${median}ms p95=${p95}ms${extra}"
}

# Generate N mock Adobe plists in a directory for scaling tests.
# Usage: gen_mock_plists <dir> <count>
gen_mock_plists() {
    local dir="$1" count="$2"
    mkdir -p "$dir"
    local i
    for ((i=1; i<=count; i++)); do
        cat > "$dir/com.adobe.MockApp${i}.plist" <<EOF
<?xml version="1.0"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.adobe.MockApp${i}</string>
</dict>
</plist>
EOF
    done
}
