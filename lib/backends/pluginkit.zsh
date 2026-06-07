#!/bin/zsh
# === Backend: pluginkit (v4.3.0) ===
# Discovery + Block/Allow for macOS pluginkit extensions
# (FinderSync, ContextMenu, QuickLook).
# Spec: lib/backends/_interface.zsh
#
# Pluginkit is orthogonal to launchd: extensions live in a separate
# subsystem DB (`pluginkit -m`) and are instantiated on demand by the system.
# `launchctl disable` does NOT apply here — hence this dedicated backend.
#
# Item format (per interface spec):
#   type:       "appex" (.appex extensions)
#   identifier: pluginkit bundle ID (e.g. "com.adobe.accmac.ACCFinderSync")
#   scope:      "user" (pluginkit is generally user-scoped, no sudo needed)
#   path:       absolute path to the .appex
#
# State: pluginkit has its own subsystem DB as the source of truth
# (`pluginkit -m -A -v` lists state '+' enabled / '-' ignored / ' ' default).
# We do NOT mirror into disabled.list — that would be redundant.

# Test override hooks (defaults stay hardened L-2 paths).
typeset -gr ATM_PLUGINKIT_BIN="${ATM_PLUGINKIT_BIN:-/usr/bin/pluginkit}"
typeset -gr ATM_PLUGINKIT_REAL_DENY="${ATM_PLUGINKIT_REAL_DENY:-0}"

# Hard guard analogous to ATM_LAUNCHCTL_REAL_DENY.
_pluginkit__pluginkit() {
    if [[ "$ATM_PLUGINKIT_REAL_DENY" == "1" && "$ATM_PLUGINKIT_BIN" == "/usr/bin/pluginkit" ]]; then
        local arg
        for arg in "$@"; do
            if [[ "$arg" == *com.adobe.* ]]; then
                print -u2 -- "FATAL: ATM_PLUGINKIT_REAL_DENY=1 — refusing real pluginkit with com.adobe.*: $arg"
                return 99
            fi
        done
    fi
    "$ATM_PLUGINKIT_BIN" "$@"
}

# === PB-05 (v4.15.0): TTL cache for `pluginkit -m -A -v` ===
# `pluginkit -m -A -v` is a macOS system call that consistently takes ~260ms
# (xpc roundtrip + state DB scan, not tunable).
# Per block_action it was previously called 1× discover + N× block/is_blocked
# = up to 11× per tick = ~2.8sec of CPU lost.
#
# Cache strategy: TTL-based (default 60s). The pluginkit state changes only
# on: (a) Adobe app update (FSEvents trigger via /Applications or
# /Library/Application Support/Adobe → daemon tick) or (b) a manual
# pluginkit -e use/ignore (either our own block/allow calls, in which case
# we invalidate explicitly, or an external user action in System Settings,
# which accepts the 60s stale window).
#
# The cache is invalidated:
# - automatically after TTL seconds
# - explicitly after a successful block/allow (state just changed)
# - explicitly via _pluginkit_cache_invalidate() (for TUI whitelist toggle etc.)
typeset -g _PLUGINKIT_RAW_CACHE=""
typeset -g _PLUGINKIT_RAW_CACHE_TS=0
typeset -gri PLUGINKIT_CACHE_TTL=60

_pluginkit_cache_invalidate() {
    _PLUGINKIT_RAW_CACHE=""
    _PLUGINKIT_RAW_CACHE_TS=0
}

# Refresh-only: ensures that _PLUGINKIT_RAW_CACHE is fresh.
# IMPORTANT: NO stdout output — otherwise the function ends up in a pipe and
# the global cache var mutations are lost in the pipeline subshell.
# The caller then reads directly from $_PLUGINKIT_RAW_CACHE.
_pluginkit_refresh_raw() {
    local now=$EPOCHSECONDS
    if [[ -n "$_PLUGINKIT_RAW_CACHE" ]] && (( now - _PLUGINKIT_RAW_CACHE_TS < PLUGINKIT_CACHE_TTL )); then
        return 0   # cache fresh, no-op
    fi
    _PLUGINKIT_RAW_CACHE=$(_pluginkit__pluginkit -m -A -v 2>/dev/null)
    _PLUGINKIT_RAW_CACHE_TS=$now
    return 0
}

pluginkit__name() {
    print -- "pluginkit"
}

# Lists all Adobe pluginkit extensions as TSV.
# `pluginkit -m -A -v` output: <state><spaces>bundle(version)\tUUID\tdate\tpath
# State: '+' = enabled, '-' = ignored, ' ' = neither (system default).
# For discovery we return ALL Adobe items (not just enabled),
# so the backend can decide via is_blocked.
#
# LOCAL_OPTIONS NO_PIPE_FAIL: the legitimate edge case "no Adobe extensions
# installed" makes grep exit 1 — that is NOT an error.
pluginkit__discover() {
    setopt LOCAL_OPTIONS NO_PIPE_FAIL
    # PB-05 (v4.15.0): refresh OUTSIDE pipe (otherwise subshell loss of the
    # global cache vars), then feed variable content into the pipe.
    _pluginkit_refresh_raw
    print -r -- "$_PLUGINKIT_RAW_CACHE" \
        | /usr/bin/grep -i adobe \
        | /usr/bin/awk 'BEGIN{FS="\t"} {
            bundle = $1
            sub(/^[+\- ][ ]+/, "", bundle)
            sub(/\([^)]*\)$/, "", bundle)
            path = $NF
            # type=appex (all pluginkit extensions are .appex)
            # scope=user (pluginkit has no system-scope concept in the same sense)
            printf "appex\t%s\tuser\t%s\n", bundle, path
        }'
}

# Block: pluginkit -e ignore -i <bundle>.
# Idempotency: checks BEFORE the call whether state is already '-' (ignored).
# Exit codes:
#   0 = newly blocked
#   1 = already blocked (ignored)
#   3 = pluginkit call failed
pluginkit__block() {
    local _type="$1" identifier="$2" _scope="$3" _path="$4"
    [[ -z "$identifier" ]] && return 3
    # State check via cached raw output (PB-05).
    _pluginkit_refresh_raw
    local current_state
    current_state=$(print -r -- "$_PLUGINKIT_RAW_CACHE" \
        | /usr/bin/grep -F " ${identifier}(" \
        | /usr/bin/awk '{print substr($0, 1, 1); exit}')
    if [[ "$current_state" == "-" ]]; then
        return 1   # already ignored
    fi
    if _pluginkit__pluginkit -e ignore -i "$identifier" 2>/dev/null; then
        # PB-05: state changed → invalidate cache so that subsequent
        # is_blocked checks are fresh
        _pluginkit_cache_invalidate
        return 0
    fi
    return 3
}

# Allow: pluginkit -e use -i <bundle>.
# Idempotency: checks BEFORE the call whether state is already '+' (enabled).
# Exit codes:
#   0 = re-activated
#   1 = already enabled (no-op)
#   3 = pluginkit call failed
pluginkit__allow() {
    local _type="$1" identifier="$2" _scope="$3" _path="$4"
    [[ -z "$identifier" ]] && return 3
    # PB-05: refresh + read from var (no subshell loss)
    _pluginkit_refresh_raw
    local current_state
    current_state=$(print -r -- "$_PLUGINKIT_RAW_CACHE" \
        | /usr/bin/grep -F " ${identifier}(" \
        | /usr/bin/awk '{print substr($0, 1, 1); exit}')
    if [[ "$current_state" == "+" ]]; then
        return 1   # already enabled
    fi
    if _pluginkit__pluginkit -e use -i "$identifier" 2>/dev/null; then
        # PB-05: state changed → invalidate cache
        _pluginkit_cache_invalidate
        return 0
    fi
    return 3
}

# is_blocked: pluginkit state is '-' (ignored).
# Exit codes per interface: 0=blocked, 1=not, 2=unknown.
pluginkit__is_blocked() {
    local _type="$1" identifier="$2" _scope="$3" _path="$4"
    [[ -z "$identifier" ]] && return 2
    # PB-05: refresh + read from var
    _pluginkit_refresh_raw
    local state
    state=$(print -r -- "$_PLUGINKIT_RAW_CACHE" \
        | /usr/bin/grep -F " ${identifier}(" \
        | /usr/bin/awk '{print substr($0, 1, 1); exit}')
    case "$state" in
        '-') return 0 ;;   # ignored = blocked
        '+') return 1 ;;   # enabled = not blocked
        ' ') return 1 ;;   # default = not blocked
        *)   return 2 ;;   # unknown / not found
    esac
}

# kill_running: kills running Adobe .appex processes.
# Uses realpath from the discover_processes pattern.
pluginkit__kill_running() {
    local pids pid
    pids=$(/bin/ps -axo pid,command 2>/dev/null \
        | /usr/bin/grep -iE "Adobe.*\.appex/Contents/MacOS" \
        | /usr/bin/grep -v grep \
        | /usr/bin/awk '{print $1}')
    [[ -z "$pids" ]] && return 0
    for pid in ${(f)pids}; do
        /bin/kill -TERM "$pid" 2>/dev/null
    done
    /bin/sleep 1
    for pid in ${(f)pids}; do
        if /bin/ps -p "$pid" >/dev/null 2>&1; then
            /bin/kill -KILL "$pid" 2>/dev/null
        fi
    done
    return 0
}
