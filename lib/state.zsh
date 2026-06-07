#!/bin/zsh
# === lib/state.zsh — Persistent state + live heartbeat state ===
# Module responsibility: state file (block|lean|allow) + live_state (heartbeat,
# counters, last-events) + filesystem permission hardening.
#
# Dependencies: log (log_warn, log_error), global ATM_BASE/STATE_FILE/
# DISCOVERED_FILE/DISABLED_FILE/LIVE_STATE_FILE/CONFIG_FILE/LOGS_DIR +
# daemon counter globals (_DAEMON_TICKS, _DAEMON_DISABLED, etc.).

# === Live-State (Daemon-Heartbeat + Counters) ===
live_state_write() {
    [[ -d "$ATM_BASE" ]] || return 0
    local tmp="$ATM_LIVE_STATE_FILE.tmp"
    # PB-08 (v4.15.0): $EPOCHSECONDS builtin (zsh/datetime) instead of /bin/date fork
    local now=$EPOCHSECONDS
    {
        print -- "heartbeat_ts=$now"
        print -- "ticks=$_DAEMON_TICKS"
        print -- "disabled=$_DAEMON_DISABLED"
        print -- "killed=$_DAEMON_KILLED"
        print -- "last_disable=$_DAEMON_LAST_DISABLE"
        print -- "last_kill=$_DAEMON_LAST_KILL"
        print -- "pending_system=$_DAEMON_PENDING_SYSTEM"
    } > "$tmp"
    /bin/mv -f "$tmp" "$ATM_LIVE_STATE_FILE"
}

live_state_read() {
    # Print key=value lines if file exists, else empty
    [[ -f "$ATM_LIVE_STATE_FILE" ]] && /bin/cat -- "$ATM_LIVE_STATE_FILE"
}

live_state_get() {
    local key="$1"
    [[ -f "$ATM_LIVE_STATE_FILE" ]] || return 1
    local line
    line=$(/usr/bin/grep -E -- "^${key}=" "$ATM_LIVE_STATE_FILE" 2>/dev/null | /usr/bin/head -1)
    [[ -z "$line" ]] && return 1
    print -- "${line#${key}=}"
}

# v4.19.1: targeted single-key update — updates a single key=value field
# atomically via tmp+mv, without touching the other daemon counters.
# Important for TUI-triggered actions (e.g. sudo_unsweep_action) that want to
# reset pending_system WITHOUT overwriting heartbeat/ticks/killed with
# 0-values (which live_state_write would do, because it writes from the
# global daemon vars — which are 0/empty in TUI mode).
live_state_set() {
    local key="$1" val="$2"
    [[ -d "$ATM_BASE" ]] || return 0
    # If the live_state file does not exist yet, write a baseline from the
    # global vars (only relevant on the very first call).
    [[ -f "$ATM_LIVE_STATE_FILE" ]] || live_state_write
    [[ -f "$ATM_LIVE_STATE_FILE" ]] || return 1
    local tmp="$ATM_LIVE_STATE_FILE.tmp.$$"
    if /usr/bin/grep -qE -- "^${key}=" "$ATM_LIVE_STATE_FILE" 2>/dev/null; then
        # Existing key → in-place update via awk (sed -E with special chars in
        # val would be more fragile; awk can substitute without a regex on $val).
        /usr/bin/awk -v k="$key" -v v="$val" -F'=' '
            $1==k {print k"="v; next}
            {print}
        ' "$ATM_LIVE_STATE_FILE" > "$tmp"
    else
        /bin/cp "$ATM_LIVE_STATE_FILE" "$tmp"
        print -- "${key}=${val}" >> "$tmp"
    fi
    /bin/mv -f "$tmp" "$ATM_LIVE_STATE_FILE"
}

# === State I/O ===
# Also hardens existing (possibly pre-v4 0644) files to 0600/0700.
_secure_atm_dirs() {
    [[ -d "$ATM_BASE" ]] && /bin/chmod 0700 "$ATM_BASE" 2>/dev/null
    [[ -d "$ATM_LOGS_DIR" ]] && /bin/chmod 0700 "$ATM_LOGS_DIR" 2>/dev/null
    # All data files to 0600 (even if they were created with 0644 before v4.0.0)
    local f
    for f in "$ATM_STATE_FILE" "$ATM_DISCOVERED_FILE" "$ATM_DISABLED_FILE" \
             "$ATM_LIVE_STATE_FILE" "$ATM_CONFIG_FILE"; do
        [[ -f "$f" ]] && /bin/chmod 0600 "$f" 2>/dev/null
    done
    # Daily logs (glob with NULL_GLOB qualifier)
    local -a logfiles
    logfiles=( "$ATM_LOGS_DIR"/*.log(.N) "$ATM_LOGS_DIR"/*.out(.N) "$ATM_LOGS_DIR"/*.err(.N) )
    (( ${#logfiles[@]} > 0 )) && /bin/chmod 0600 "${logfiles[@]}" 2>/dev/null
    return 0
}

init_state() {
    if [[ ! -d "$ATM_BASE" ]]; then
        /bin/mkdir -p "$ATM_BASE" 2>/dev/null || return 1
    fi
    _secure_atm_dirs
    if [[ ! -f "$ATM_STATE_FILE" ]]; then
        write_state block
    fi
    # v4.14.0 (S-07): defense-in-depth integrity check of disabled.list
    # Calls the function if it exists (= disabled_list.zsh sourced).
    if (( ${+functions[disabled_list_validate_integrity]} )); then
        disabled_list_validate_integrity 2>/dev/null || true
    fi
}

read_state() {
    if [[ ! -f "$ATM_STATE_FILE" ]]; then
        log_warn "state file missing, fallback to block"
        print -- "block"
        return 0
    fi
    local s=""
    # read first line (strips trailing newline automatically)
    read -r s < "$ATM_STATE_FILE" 2>/dev/null || true
    # In case the file was empty
    [[ -z "$s" ]] && { log_warn "state file empty, fallback to block"; print -- "block"; return 0; }
    case "$s" in
        block|lean|allow) print -- "$s" ;;
        *) log_warn "state file corrupt ('$s'), fallback to block"; print -- "block" ;;
    esac
}

write_state() {
    local new="$1"
    case "$new" in
        block|lean|allow) ;;
        *) log_error "write_state: invalid value '$new'"; return 2 ;;
    esac
    [[ -d "$ATM_BASE" ]] || /bin/mkdir -p "$ATM_BASE" || return 1
    # v4.1.1 SEC-5 fix: include $$ in tmp path to avoid race when two
    # write_state calls are concurrent (previously both wrote to the same
    # '.tmp' path → one mv succeeds, other fails with 'No such file').
    # Atomic rename via mv stays POSIX-atomic on the same filesystem.
    local tmp="${ATM_STATE_FILE}.tmp.$$"
    print -- "$new" > "$tmp" || return 1
    /bin/mv -f "$tmp" "$ATM_STATE_FILE" || return 1
    return 0
}
