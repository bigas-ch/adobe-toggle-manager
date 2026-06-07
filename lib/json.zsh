#!/bin/zsh
# === lib/json.zsh — Pure-zsh JSON encoder (v4.7.0) ===
# Module responsibility: minimal RFC-8259-compliant encoder + emit functions
# for status/discovery/summary --json. Zero runtime deps (no jq/python).
#
# Non-goal: JSON parser (zsh natives are enough for pure output generation).
# Untrusted-input protection: all string values are escaped via json_str,
# never embedded directly — otherwise injection with paths containing ", \, \n, etc.
#
# Dependencies: state (read_state, live_state_get), disabled_list (cat),
# globals APP_VERSION/APP_LABEL/ATM_DISCOVERED_FILE/ATM_DISABLED_FILE/
# ATM_LIVE_STATE_FILE/ATM_BASE/_DAEMON_TICKS/_BACKENDS_AVAILABLE.

# === Primitives ===

# json_str <value> — emit "quoted-and-escaped string" (no trailing newline).
# Escape set: \, ", \n, \r, \t (common cases). Other control chars (0x00-1F)
# practically never occur in our sources (labels validated, paths on
# macOS, ISO timestamps).
#
# Bug in v4.7.0–v4.11.0 (fixed in v4.12.0): ${v//$'\n'/\\n} does NOT work in zsh
# — newlines stayed unescaped. Use zsh-native field-split + join for
# newline + carriage-return.
json_str() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    # Newline escape: zsh ${//$'\n'/...} does not work; ${(j[\\n])} produces
    # 2 backslashes instead of 1 in function context (zsh quoting quirk).
    # A manual loop with single-quoted '\n' deterministically yields 1 backslash + n.
    if [[ "$s" == *$'\n'* ]]; then
        local -a parts=( "${(@f)s}" )
        local out="${parts[1]}"
        local i
        for (( i=2; i<=${#parts}; i++ )); do
            out="${out}"'\n'"${parts[i]}"
        done
        s="$out"
    fi
    if [[ "$s" == *$'\r'* ]]; then
        local -a parts=( ${(s[$'\r'])s} )
        local out="${parts[1]}"
        local i
        for (( i=2; i<=${#parts}; i++ )); do
            out="${out}"'\r'"${parts[i]}"
        done
        s="$out"
    fi
    print -rn -- "\"$s\""
}

# json_num <value> — emit number unquoted; if non-numeric, falls back to
# json_str (defensive, no invalid JSON).
json_num() {
    local v="${1-}"
    if [[ "$v" == <-> || "$v" == -<-> ]]; then
        print -rn -- "$v"
    elif [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        print -rn -- "$v"
    else
        json_str "$v"
    fi
}

# json_bool <0|1|true|false|yes|no> — emit JSON true/false literal.
json_bool() {
    case "${1-}" in
        1|true|yes) print -rn -- "true" ;;
        *) print -rn -- "false" ;;
    esac
}

# json_null — emit literal null.
json_null() { print -rn -- "null"; }

# === Helpers for status/discovery/summary ===

# _json_daemon_pid — PID from launchctl print, "0" if not found.
_json_daemon_pid() {
    local pid
    pid=$(_launchctl print "gui/${UID}/${APP_LABEL}" 2>/dev/null \
        | /usr/bin/awk '/pid =/ {gsub(/[^0-9]/, "", $3); print $3; exit}')
    print -- "${pid:-0}"
}

# _json_pidfile_pid — PID from daemon.pid file (single-instance lock).
_json_pidfile_pid() {
    [[ -f "$ATM_PID_FILE" ]] || { print -- "0"; return; }
    local pid
    read -r pid < "$ATM_PID_FILE" 2>/dev/null || pid=""
    print -- "${pid:-0}"
}

# _json_tick_interval — tick-interval read from config (otherwise default).
_json_tick_interval() {
    local v
    if [[ -f "$ATM_CONFIG_FILE" ]]; then
        v=$(/usr/bin/grep -E -- "^tick-interval=" "$ATM_CONFIG_FILE" 2>/dev/null \
            | /usr/bin/head -1)
        v="${v#tick-interval=}"
    fi
    print -- "${v:-$DEFAULT_TICK_INTERVAL}"
}

# _json_safety_tick_interval — outer bound between heartbeats when the FSEvents
# watcher is active (5 min default) — relevant for the health threshold.
_json_safety_tick_interval() {
    local v
    if [[ -f "$ATM_CONFIG_FILE" ]]; then
        v=$(/usr/bin/grep -E -- "^safety-tick-interval=" "$ATM_CONFIG_FILE" 2>/dev/null \
            | /usr/bin/head -1)
        v="${v#safety-tick-interval=}"
    fi
    print -- "${v:-$DEFAULT_SAFETY_TICK_INTERVAL}"
}

# _json_health <pid> <heartbeat_age_s> <safety_tick_interval_s>
# Healthy = (pid != 0 AND alive) AND (heartbeat_age < 2*safety_tick_interval).
# safety_tick_interval is the UPPER bound between heartbeats — with an active
# FSEvents watcher the daemon only ticks on file events plus the 5-min
# safety-tick. tick_interval (30s) is only relevant without the watcher.
# Sets global out-vars _JSON_HEALTHY (true|false) + _JSON_HEALTH_REASON.
_json_health() {
    local pid="$1" age="$2" interval="$3"
    typeset -g _JSON_HEALTHY="false"
    typeset -g _JSON_HEALTH_REASON=""
    if (( pid == 0 )); then
        _JSON_HEALTH_REASON="no-pid"
        return
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        _JSON_HEALTH_REASON="pid-not-alive"
        return
    fi
    if [[ "$age" == "null" ]]; then
        _JSON_HEALTH_REASON="no-heartbeat"
        return
    fi
    local threshold=$(( interval * 2 ))
    if (( age > threshold )); then
        _JSON_HEALTH_REASON="heartbeat-stale (>${threshold}s)"
        return
    fi
    _JSON_HEALTHY="true"
    _JSON_HEALTH_REASON="ok"
}

# === Emit: status ===
# Output:
#   {"version":"1.0.0","state":"block","daemon":{...},"backends":{...}}
json_emit_status() {
    local state pid pidfile_pid ticks heartbeat_ts heartbeat_age tick_interval safety_interval
    state=$(read_state 2>/dev/null) || state="unknown"
    pid=$(_json_daemon_pid)
    pidfile_pid=$(_json_pidfile_pid)
    ticks=$(live_state_get ticks 2>/dev/null || print -- "0")
    ticks="${ticks:-0}"
    heartbeat_ts=$(live_state_get heartbeat_ts 2>/dev/null)
    tick_interval=$(_json_tick_interval)
    safety_interval=$(_json_safety_tick_interval)
    if [[ -n "$heartbeat_ts" && "$heartbeat_ts" == <-> ]]; then
        # PB-08 (v4.15.0): $EPOCHSECONDS builtin (zsh/datetime) instead of /bin/date fork
        heartbeat_age=$(( EPOCHSECONDS - heartbeat_ts ))
    else
        heartbeat_age="null"
        heartbeat_ts="null"
    fi
    _json_health "$pid" "$heartbeat_age" "$safety_interval"

    print -rn -- "{"
    print -rn -- "\"version\":"; json_str "$APP_VERSION"; print -rn -- ","
    print -rn -- "\"label\":"; json_str "$APP_LABEL"; print -rn -- ","
    print -rn -- "\"state\":"; json_str "$state"; print -rn -- ","
    print -rn -- "\"daemon\":{"
    print -rn -- "\"pid\":"; json_num "$pid"; print -rn -- ","
    print -rn -- "\"pidfile_pid\":"; json_num "$pidfile_pid"; print -rn -- ","
    print -rn -- "\"ticks\":"; json_num "$ticks"; print -rn -- ","
    print -rn -- "\"heartbeat_ts\":"; json_num "$heartbeat_ts"; print -rn -- ","
    print -rn -- "\"heartbeat_age_s\":"; json_num "$heartbeat_age"; print -rn -- ","
    print -rn -- "\"tick_interval_s\":"; json_num "$tick_interval"; print -rn -- ","
    print -rn -- "\"safety_tick_interval_s\":"; json_num "$safety_interval"; print -rn -- ","
    print -rn -- "\"healthy\":"; json_bool "$_JSON_HEALTHY"; print -rn -- ","
    print -rn -- "\"healthy_reason\":"; json_str "$_JSON_HEALTH_REASON"
    print -rn -- "},"
    print -rn -- "\"backends\":{"
    print -rn -- "\"available\":"; json_bool "$_BACKENDS_AVAILABLE"
    print -rn -- "}"
    print -- "}"
}

# === Emit: discovery ===
# discovered.list format: backend\tlabel\tpath\tscope (TSV, 4 cols).
# Output: {"discovered":[{"backend":"launchd","label":"...","path":"...","scope":"system"},...]}
json_emit_discovery() {
    print -rn -- "{\"discovered\":["
    if [[ -f "$ATM_DISCOVERED_FILE" ]]; then
        local first=1 backend label path scope
        while IFS=$'\t' read -r backend label path scope; do
            [[ -z "$backend" ]] && continue
            if (( first )); then first=0; else print -rn -- ","; fi
            print -rn -- "{"
            print -rn -- "\"backend\":"; json_str "$backend"; print -rn -- ","
            print -rn -- "\"label\":"; json_str "$label"; print -rn -- ","
            print -rn -- "\"path\":"; json_str "$path"; print -rn -- ","
            print -rn -- "\"scope\":"; json_str "$scope"
            print -rn -- "}"
        done < "$ATM_DISCOVERED_FILE"
    fi
    print -- "]}"
}

# === Emit: summary ===
# Aggregated view: state + daemon status + disabled.list + discovered.list count.
json_emit_summary() {
    local state pid ticks heartbeat_ts tick_interval
    state=$(read_state 2>/dev/null) || state="unknown"
    pid=$(_json_daemon_pid)
    ticks=$(live_state_get ticks 2>/dev/null || print -- "0")
    ticks="${ticks:-0}"
    heartbeat_ts=$(live_state_get heartbeat_ts 2>/dev/null)
    [[ -n "$heartbeat_ts" && "$heartbeat_ts" == <-> ]] || heartbeat_ts="null"
    tick_interval=$(_json_tick_interval)

    local discovered_count=0 disabled_count=0
    [[ -f "$ATM_DISCOVERED_FILE" ]] && discovered_count=$(/usr/bin/wc -l < "$ATM_DISCOVERED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    [[ -f "$ATM_DISABLED_FILE" ]] && disabled_count=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')

    print -rn -- "{"
    print -rn -- "\"version\":"; json_str "$APP_VERSION"; print -rn -- ","
    print -rn -- "\"state\":"; json_str "$state"; print -rn -- ","
    print -rn -- "\"daemon\":{"
    print -rn -- "\"pid\":"; json_num "$pid"; print -rn -- ","
    print -rn -- "\"ticks\":"; json_num "$ticks"; print -rn -- ","
    print -rn -- "\"heartbeat_ts\":"; json_num "$heartbeat_ts"; print -rn -- ","
    print -rn -- "\"tick_interval_s\":"; json_num "$tick_interval"
    print -rn -- "},"
    print -rn -- "\"discovered_count\":"; json_num "$discovered_count"; print -rn -- ","
    print -rn -- "\"disabled_count\":"; json_num "$disabled_count"; print -rn -- ","
    print -rn -- "\"disabled\":["
    if [[ -f "$ATM_DISABLED_FILE" ]]; then
        local first=1 label scope ts
        while IFS=$'\t' read -r label scope ts; do
            [[ -z "$label" ]] && continue
            if (( first )); then first=0; else print -rn -- ","; fi
            print -rn -- "{"
            print -rn -- "\"label\":"; json_str "$label"; print -rn -- ","
            print -rn -- "\"scope\":"; json_str "$scope"; print -rn -- ","
            print -rn -- "\"disabled_at\":"; json_str "$ts"
            print -rn -- "}"
        done < "$ATM_DISABLED_FILE"
    fi
    print -- "]}"
}
