#!/bin/zsh
# === lib/config.zsh — KEY=VALUE config file I/O ===
# Module responsibility: get/set/show + config subcommand dispatcher.
# Format: KEY=VALUE per line.
#
# Dependencies: log (log_warn indirectly), global ATM_BASE/ATM_CONFIG_FILE +
# defaults DEFAULT_TICK_INTERVAL, DEFAULT_NOTIFICATIONS, DEFAULT_AUTO_START_CC.

config_get() {
    local key="$1"
    [[ -f "$ATM_CONFIG_FILE" ]] || return 1
    local line
    line=$(/usr/bin/grep -E -- "^${key}=" "$ATM_CONFIG_FILE" 2>/dev/null | /usr/bin/tail -1)
    [[ -z "$line" ]] && return 1
    print -- "${line#${key}=}"
}

# Known config keys (allowlist). Unknown keys are rejected so that typos
# (e.g. tick-intervl) are not silently swallowed into the config file.
typeset -ga ATM_CONFIG_KNOWN_KEYS=(
    tick-interval
    safety-tick-interval
    notifications
    auto-start-cc
    auto-sudo-sweep
    adaptive-interval
)

# Validate a key/value pair against the allowlist + value domains.
# Returns 0 if valid, non-zero (+ stderr message) otherwise.
config_validate() {
    local key="$1" value="$2"
    # Key allowlist. (ie) = index of exact element; returns len+1 if absent
    # (NO_UNSET-safe, unlike (r) which yields an unset value on no match).
    if (( ${ATM_CONFIG_KNOWN_KEYS[(ie)$key]} > ${#ATM_CONFIG_KNOWN_KEYS} )); then
        print -u2 -- "config_set: unknown key '$key'"
        print -u2 -- "config_set: valid keys: ${ATM_CONFIG_KNOWN_KEYS[*]}"
        return 2
    fi
    # Value domain per key.
    case "$key" in
        tick-interval|safety-tick-interval)
            # <1-> = positive integer; 0 would make the daemon busy-loop (sleep 0).
            if [[ "$value" != <1-> ]]; then
                print -u2 -- "config_set: '$key' expects a positive integer (>= 1), got '$value'"
                return 3
            fi
            ;;
        notifications)
            if [[ "$value" != "minimal" && "$value" != "off" ]]; then
                print -u2 -- "config_set: '$key' must be one of: minimal off (got '$value')"
                return 3
            fi
            ;;
        auto-start-cc|auto-sudo-sweep|adaptive-interval)
            if [[ "$value" != "true" && "$value" != "false" ]]; then
                print -u2 -- "config_set: '$key' must be one of: true false (got '$value')"
                return 3
            fi
            ;;
    esac
    return 0
}

config_set() {
    local key="$1" value="$2"
    [[ -z "$key" ]] && { print -u2 -- "config_set: empty key"; return 2; }
    config_validate "$key" "$value" || return $?
    [[ -d "$ATM_BASE" ]] || /bin/mkdir -p "$ATM_BASE" || return 1
    /usr/bin/touch "$ATM_CONFIG_FILE"
    local tmp="$ATM_CONFIG_FILE.tmp"
    /usr/bin/grep -v -E -- "^${key}=" "$ATM_CONFIG_FILE" > "$tmp" 2>/dev/null || true
    print -- "${key}=${value}" >> "$tmp"
    /bin/mv -f "$tmp" "$ATM_CONFIG_FILE"
    # Echo the effective value on success.
    print -- "$value"
}

config_show() {
    [[ -f "$ATM_CONFIG_FILE" ]] && /bin/cat -- "$ATM_CONFIG_FILE"
    print -- "tick-interval=$(config_get tick-interval 2>/dev/null || print $DEFAULT_TICK_INTERVAL) (effective, fallback without watcher)"
    print -- "safety-tick-interval=$(config_get safety-tick-interval 2>/dev/null || print $DEFAULT_SAFETY_TICK_INTERVAL) (effective, with watcher)"
    print -- "notifications=$(config_get notifications 2>/dev/null || print $DEFAULT_NOTIFICATIONS) (effective)"
    print -- "auto-start-cc=$(config_get auto-start-cc 2>/dev/null || print $DEFAULT_AUTO_START_CC) (effective)"
    print -- "auto-sudo-sweep=$(config_get auto-sudo-sweep 2>/dev/null || print $DEFAULT_AUTO_SUDO_SWEEP) (effective)"
    # adaptive-interval has no DEFAULT_ const; the daemon treats anything but
    # "true" as off, so the effective default is the literal "false".
    print -- "adaptive-interval=$(config_get adaptive-interval 2>/dev/null || print false) (effective)"
}

config_main() {
    local sub="${1:-show}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
        show) config_show ;;
        get) config_get "$@" ;;
        set) config_set "$@" ;;
        *) print -u2 -- "Unknown config sub-command: $sub"; return 2 ;;
    esac
}
