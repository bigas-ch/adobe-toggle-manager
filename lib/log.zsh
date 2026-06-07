#!/bin/zsh
# === lib/log.zsh — daily NDJSON logging with 90-day retention (v4.12.0+) ===
# Module responsibility: all logging functions (info/warn/error/event journal)
# + log_cleanup for retention.
#
# Format change in v4.12.0: CSV → NDJSON (newline-delimited JSON).
# Advantage: jq-pipeable, structured queries, robust against commas in messages.
# Backward-compat: legacy CSV files (.log) stay visible for the 90d retention
# and are cleaned up alongside by log_cleanup. New writes are .ndjson.
#
# Dependencies: $ATM_LOGS_DIR (global, set in main),
# json_str (lib/json.zsh) — if not yet loaded, falls back to _log_escape.
# Consumers: all libs (state, discovery, daemon, tui, pam) + main.

# === Daily file paths (v4.12.0+: .ndjson instead of .log) ===
_today_log_file()   { print -- "$ATM_LOGS_DIR/adobe-toggle.$(/bin/date +%Y-%m-%d).ndjson"; }
_today_events_file() { print -- "$ATM_LOGS_DIR/adobe-toggle.$(/bin/date +%Y-%m-%d).events.ndjson"; }

# === JSON string escape (fallback when json.zsh is not yet loaded) ===
# log.zsh is sourced BEFORE json.zsh → for very early log calls
# (theoretical, not relevant in practice) json_str is not available.
_log_escape() {
    if (( ${+functions[json_str]} )); then
        json_str "$1"
    else
        # Fallback identical to json_str (see the comment there on the newline logic).
        local v="${1-}"
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        v="${v//$'\t'/\\t}"
        if [[ "$v" == *$'\n'* ]]; then
            local -a parts=( "${(@f)v}" )
            local out="${parts[1]}"
            local i
            for (( i=2; i<=${#parts}; i++ )); do
                out="${out}"'\n'"${parts[i]}"
            done
            v="$out"
        fi
        if [[ "$v" == *$'\r'* ]]; then
            local -a parts=( ${(s[$'\r'])v} )
            local out="${parts[1]}"
            local i
            for (( i=2; i<=${#parts}; i++ )); do
                out="${out}"'\r'"${parts[i]}"
            done
            v="$out"
        fi
        print -rn -- "\"$v\""
    fi
}

# === Generic log with level (NDJSON) ===
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
    [[ -d "$ATM_LOGS_DIR" ]] || /bin/mkdir -p "$ATM_LOGS_DIR" 2>/dev/null
    # print -r: raw, no escape interpretation. Otherwise correctly escaped
    # \n / \t / \\ in the json strings would be re-interpreted (broken NDJSON).
    print -r -- "{\"ts\":$(_log_escape "$ts"),\"level\":$(_log_escape "$level"),\"msg\":$(_log_escape "$msg")}" >> "$(_today_log_file)"
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

# === Event log (separate file for DAEMON_START/STOP/STATE_CHANGE/etc.) ===
# v4.12.0: NDJSON with structured fields {ts, event, details}.
# 'details' stays a composed string (legacy compatibility with
# existing callsites like 'log_event DISABLED "label:scope"').
# v4.17.0 (E-05): additionally log_event_structured for a jq-pipeable
# fields object. Both functions coexist, migration callsite-by-callsite.
log_event() {
    local event="$1"; shift
    local details="$*"
    local ts
    ts=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
    [[ -d "$ATM_LOGS_DIR" ]] || /bin/mkdir -p "$ATM_LOGS_DIR" 2>/dev/null
    # print -r: raw, see _log() for the rationale.
    print -r -- "{\"ts\":$(_log_escape "$ts"),\"event\":$(_log_escape "$event"),\"details\":$(_log_escape "$details")}" >> "$(_today_events_file)"
}

# === log_event_structured (E-05, v4.17.0) ===
# Structured variant: writes {ts, event, fields:{key1:val1, key2:val2}}.
# Args: EVENT_NAME key1=val1 key2=val2 ...
#
# Type coercion: only pure integers (^[0-9]+$) are written as a JSON number,
# everything else as a string (with RFC 8259 escaping via _log_escape).
# Deliberately conservative — no float detection, no bool detection, no null
# detection (those would be edge-case sources).
#
# Example:
#   log_event_structured HEALTHCHECK_OK pid=12345 age_s=300
#   → {"ts":"...","event":"HEALTHCHECK_OK","fields":{"pid":12345,"age_s":300}}
#
# Consumer pattern (jq):
#   jq 'select(.event == "HEALTHCHECK_OK") | .fields.age_s' adobe-toggle.*.events.ndjson
log_event_structured() {
    local event="$1"; shift
    local ts
    ts=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
    [[ -d "$ATM_LOGS_DIR" ]] || /bin/mkdir -p "$ATM_LOGS_DIR" 2>/dev/null
    # Build the fields object manually (no jq dependency, use json.zsh primitives)
    local fields_json="{"
    local first=1
    local pair key val
    for pair in "$@"; do
        # Split at the first '=' (values may contain further '=')
        key="${pair%%=*}"
        val="${pair#*=}"
        # Skip if key is empty or pair=key without '=' (= no value)
        [[ -z "$key" || "$key" == "$pair" ]] && continue
        (( first )) && first=0 || fields_json+=","
        # Key always as a string key
        fields_json+="$(_log_escape "$key"):"
        # Value: integer (digits only) → number, otherwise escaped string
        if [[ "$val" == <-> ]]; then
            fields_json+="$val"
        else
            fields_json+="$(_log_escape "$val")"
        fi
    done
    fields_json+="}"
    print -r -- "{\"ts\":$(_log_escape "$ts"),\"event\":$(_log_escape "$event"),\"fields\":${fields_json}}" >> "$(_today_events_file)"
}

# === Clean up old logs (older than LOG_RETENTION_DAYS) ===
# v4.12.0: deletes both old .log (legacy CSV) and new .ndjson.
log_cleanup() {
    [[ -d "$ATM_LOGS_DIR" ]] || return 0
    /usr/bin/find "$ATM_LOGS_DIR" -maxdepth 1 -type f \
        \( -name "adobe-toggle.*.log" -o -name "adobe-toggle.*.events.log" \
           -o -name "adobe-toggle.*.ndjson" -o -name "adobe-toggle.*.events.ndjson" \) \
        -mtime +"${LOG_RETENTION_DAYS}" -delete 2>/dev/null
}
