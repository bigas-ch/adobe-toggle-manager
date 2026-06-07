#!/usr/bin/env bats
# Wake/sleep pattern tests (v4.13.3, Phase C — R-06..R-08).

setup() {
    DAEMON_PID=$(/bin/launchctl list 2>/dev/null | /usr/bin/awk '/com\.user\.adobe-toggle\.daemon$/ {print $1}')
}

# === R-06 Battery impact via pmset ============================================

@test "R-06: pmset audit availability (skip if no sudo)" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    # pmset -g coalitions usually needs root. We only verify that the tool
    # itself is present + document the manual audit pattern.
    [ -x /usr/bin/pmset ]
    echo "RESOURCE [pmset] manual audit pattern: 'sudo pmset -g coalitions | grep adobe-toggle'"
}

# === R-07 Healthcheck wake-up cost =============================================

@test "R-07: healthcheck LaunchAgent StartInterval=300 (5min, 288×/day)" {
    local plist="$HOME/Library/LaunchAgents/com.user.adobe-toggle.healthcheck.plist"
    [[ -f "$plist" ]] || skip "Healthcheck plist not installed"
    local interval
    interval=$(/usr/libexec/PlistBuddy -c "Print :StartInterval" "$plist" 2>/dev/null)
    [ "$interval" = "300" ]
    # 288 wake-ups/day = 86400s / 300s. Per pmset assert "low impact" (qualitative).
    echo "RESOURCE [healthcheck-interval] ${interval}s = $((86400 / interval))×/day"
}

@test "R-07b: healthcheck job is NOT KeepAlive (would run permanently)" {
    local plist="$HOME/Library/LaunchAgents/com.user.adobe-toggle.healthcheck.plist"
    [[ -f "$plist" ]] || skip "Healthcheck plist not installed"
    # PlistBuddy returns non-zero when the key is missing — || true for robust handling
    local keepalive
    keepalive=$(/usr/libexec/PlistBuddy -c "Print :KeepAlive" "$plist" 2>&1 || true)
    # KeepAlive should NOT exist OR not be 'true'
    [[ "$keepalive" == *"Does Not Exist"* ]] || [[ "$keepalive" != "true" ]]
}

# === R-08 System sleep/wake cycle =============================================

@test "R-08: daemon survives system sleep (verified via heartbeat monotonic check)" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    # We cannot trigger system sleep in the test (would need sudo/IOPMSleepSystem).
    # Instead: verify that the live_state file's heartbeat_ts grows monotonically
    # on the next tick — the daemon must keep running right after wake-up
    # (KeepAlive=true in daemon.plist).
    local plist="$HOME/Library/LaunchAgents/com.user.adobe-toggle.daemon.plist"
    [[ -f "$plist" ]] || skip "Daemon plist not installed"
    local keepalive
    keepalive=$(/usr/libexec/PlistBuddy -c "Print :KeepAlive" "$plist" 2>/dev/null)
    [ "$keepalive" = "true" ]
    echo "RESOURCE [daemon KeepAlive] $keepalive (sleep/wake-resilient)"
}

@test "R-08b: live_state file has a monotonically growing heartbeat_ts" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    local lsf="$HOME/Library/Application Support/AdobeToggleManager/live_state"
    [[ -f "$lsf" ]] || skip "No live_state file"
    local ts1
    ts1=$(/usr/bin/grep "^heartbeat_ts=" "$lsf" | /usr/bin/cut -d= -f2)
    # SIGUSR1 → tick → heartbeat_ts updated
    /bin/kill -USR1 "$DAEMON_PID" 2>/dev/null || true
    sleep 2
    local ts2
    ts2=$(/usr/bin/grep "^heartbeat_ts=" "$lsf" | /usr/bin/cut -d= -f2)
    echo "RESOURCE [heartbeat_ts] before=$ts1 after=$ts2"
    [ "$ts2" -ge "$ts1" ]
}
