#!/usr/bin/env bats
# Resource idle tests (v4.13.3, Phase C — R-01..R-05).
#
# These tests measure the LIVE daemon (com.user.adobe-toggle.daemon) when
# installed. If no live daemon: skip with a note.
# bats file_tags=perf

setup() {
    DAEMON_PID=$(/bin/launchctl list 2>/dev/null | /usr/bin/awk '/com\.user\.adobe-toggle\.daemon$/ {print $1}')
}

# === R-01 Daemon idle CPU =====================================================

@test "R-01: daemon idle CPU < 5% over a 10s sample" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon installed"
    # ps -o %cpu over 10s with a 1s interval (10 samples)
    local samples=()
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        local cpu
        cpu=$(/bin/ps -o %cpu= -p "$DAEMON_PID" 2>/dev/null | /usr/bin/tr -d ' ')
        [[ -n "$cpu" ]] && samples+=( "$cpu" )
        sleep 1
    done
    [ "${#samples[@]}" -ge 5 ]   # at least 5 samples collected
    # Compute the median
    local median
    median=$(printf '%s\n' "${samples[@]}" | /usr/bin/sort -n | /usr/bin/awk -v n="${#samples[@]}" 'NR==int((n+1)/2) {print int($1)}')
    echo "RESOURCE [daemon idle CPU] median=${median}% samples=${samples[*]}"
    # Cap: 5% — a moderate target, an FSEvents daemon should be practically idle
    [ "${median:-0}" -lt 5 ]
}

# === R-02 Watcher idle CPU ====================================================

@test "R-02: atm-watcher subprocess idle CPU < 5%" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    # Watcher is a child process of the daemon (xcrun swift)
    local watcher_pid
    watcher_pid=$(/bin/ps -axo ppid,pid,command 2>/dev/null \
        | /usr/bin/awk -v dp="$DAEMON_PID" '$1==dp && /atm-watcher\.swift/ {print $2; exit}')
    [[ -z "$watcher_pid" ]] && skip "No watcher subprocess (possible if xcrun is missing)"

    local samples=()
    local i
    for i in 1 2 3 4 5; do
        local cpu
        cpu=$(/bin/ps -o %cpu= -p "$watcher_pid" 2>/dev/null | /usr/bin/tr -d ' ')
        [[ -n "$cpu" ]] && samples+=( "$cpu" )
        sleep 1
    done
    local median
    median=$(printf '%s\n' "${samples[@]}" | /usr/bin/sort -n | /usr/bin/awk -v n="${#samples[@]}" 'NR==int((n+1)/2) {print int($1)}')
    echo "RESOURCE [watcher idle CPU] median=${median}%"
    [ "${median:-0}" -lt 5 ]
}

# === R-03 Memory-Footprint =====================================================

@test "R-03: daemon memory < 50MB (RSS via ps)" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    local rss_kb
    rss_kb=$(/bin/ps -o rss= -p "$DAEMON_PID" 2>/dev/null | /usr/bin/tr -d ' ')
    [[ -n "$rss_kb" ]] || skip "ps -o rss returned empty"
    local rss_mb=$(( rss_kb / 1024 ))
    echo "RESOURCE [daemon RSS] ${rss_mb}MB (${rss_kb}KB)"
    [ "$rss_mb" -lt 50 ]
}

@test "R-03b: watcher memory < 200MB (xcrun swift interpreter baseline ~140MB)" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    local watcher_pid
    watcher_pid=$(/bin/ps -axo ppid,pid,command 2>/dev/null \
        | /usr/bin/awk -v dp="$DAEMON_PID" '$1==dp && /atm-watcher\.swift/ {print $2; exit}')
    [[ -z "$watcher_pid" ]] && skip "No watcher subprocess"
    local rss_kb
    rss_kb=$(/bin/ps -o rss= -p "$watcher_pid" 2>/dev/null | /usr/bin/tr -d ' ')
    [[ -n "$rss_kb" ]] || skip "ps -o rss returned empty"
    local rss_mb=$(( rss_kb / 1024 ))
    echo "RESOURCE [watcher RSS] ${rss_mb}MB"
    # The xcrun swift interpreter has a ~140MB baseline (measured v4.13.3) — 200MB cap
    [ "$rss_mb" -lt 200 ]
}

# === R-04 File descriptor count ===============================================

@test "R-04: daemon FD count < 50" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    local fd_count
    fd_count=$(/usr/sbin/lsof -p "$DAEMON_PID" 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo "RESOURCE [daemon FD-count] ${fd_count}"
    # Reasonable cap: 50 FDs (stdio + log files + state files + lib/ sources)
    [ "${fd_count:-0}" -lt 50 ]
}

# === R-05 Disk usage (logs) ===================================================

@test "R-05: logs directory < 10MB (90d retention enforced)" {
    local log_dir="$HOME/Library/Application Support/AdobeToggleManager/logs"
    [[ -d "$log_dir" ]] || skip "No logs dir"
    local total_kb
    total_kb=$(/usr/bin/du -sk "$log_dir" 2>/dev/null | /usr/bin/awk '{print $1}')
    local total_mb=$(( total_kb / 1024 ))
    echo "RESOURCE [logs disk-usage] ${total_mb}MB (${total_kb}KB)"
    # Sanity: <10MB after 90d retention
    [ "$total_mb" -lt 10 ]
}

@test "R-05b: log_cleanup function exists + is callable" {
    /usr/bin/grep -q "^log_cleanup()" lib/log.zsh
    /usr/bin/grep -q "LOG_RETENTION_DAYS" lib/log.zsh
}
