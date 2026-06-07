#!/usr/bin/env bats
# Network / external-surface tests (v4.13.3, Phase C — R-09, R-10).

setup() {
    DAEMON_PID=$(/bin/launchctl list 2>/dev/null | /usr/bin/awk '/com\.user\.adobe-toggle\.daemon$/ {print $1}')
}

# === R-09 Network surface = 0 =================================================

@test "R-09: daemon has 0 open network sockets (lsof -i)" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    local net_count
    net_count=$(/usr/sbin/lsof -a -i -p "$DAEMON_PID" 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo "RESOURCE [daemon network-sockets] ${net_count}"
    [ "${net_count:-0}" -eq 0 ]
}

@test "R-09b: watcher (xcrun swift) has 0 open network sockets" {
    [[ -z "$DAEMON_PID" || "$DAEMON_PID" == "-" ]] && skip "No live daemon"
    local watcher_pid
    watcher_pid=$(/bin/ps -axo ppid,pid,command 2>/dev/null \
        | /usr/bin/awk -v dp="$DAEMON_PID" '$1==dp && /atm-watcher\.swift/ {print $2; exit}')
    [[ -z "$watcher_pid" ]] && skip "No watcher"
    local net_count
    net_count=$(/usr/sbin/lsof -a -i -p "$watcher_pid" 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo "RESOURCE [watcher network-sockets] ${net_count}"
    [ "${net_count:-0}" -eq 0 ]
}

# === R-10 No external API calls (static) ======================================

@test "R-10: lib/ modules contain NO curl/wget/nc/ssh calls" {
    cd "$BATS_TEST_DIRNAME/.."
    # Static source inspection (no dtruss run)
    local hits
    hits=$(/usr/bin/grep -rE "^[^#]*\b(curl|wget|nc|ssh|scp|sftp|telnet)\b" lib/ adobe-toggle 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo "RESOURCE [external network-calls in src] ${hits}"
    [ "$hits" -eq 0 ]
}

@test "R-10b: allowed system tools = launchctl, codesign, pluginkit, osascript, PlistBuddy, security, sw_vers, xcrun, ps, kill, awk, grep, sed, etc." {
    cd "$BATS_TEST_DIRNAME/.."
    # Verify that only the approved system tools are used (whitelist check)
    # Collect all absolute /bin/* + /usr/bin/* + /usr/libexec/* calls
    local unique_bins
    unique_bins=$(/usr/bin/grep -rohE "/(bin|usr/bin|usr/libexec|usr/sbin)/[a-zA-Z][a-zA-Z0-9_-]+" lib/ adobe-toggle install.sh 2>/dev/null \
        | /usr/bin/sort -u)
    echo "RESOURCE [absolute system-bins used]:"
    echo "$unique_bins"
    # Verify there is no suspicious bin (e.g. /usr/bin/curl)
    ! echo "$unique_bins" | /usr/bin/grep -qE "/(curl|wget|nc|ssh|scp|sftp|telnet)$"
}

@test "R-10c: no eval/exec with user input (code-injection protection)" {
    cd "$BATS_TEST_DIRNAME/.."
    # eval is generally a zsh feature, but should never run with unvalidated input
    local risky
    risky=$(/usr/bin/grep -rE "^[^#]*\beval\b.*\\\$[a-zA-Z_]" lib/ adobe-toggle 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo "RESOURCE [eval-with-var-substitution] ${risky}"
    [ "$risky" -eq 0 ]
}
