#!/bin/zsh
# === lib/disabled_list.zsh — Per-component state (TSV-I/O) ===
# Module responsibility: read/write/remove/clear the disabled.list.
#
# Format (v4.8.0+, 4 columns): label\tscope\tdisabled_at\tstate
# Format (v4.0.x–v4.7.x, 3 columns, legacy): label\tscope\tdisabled_at
#   → is lazily migrated to state=auto_blocked when read.
#
# State values (v4.8.0+):
#   auto_blocked  Daemon blocked it during the tick (default for newly-discovered)
#   user_blocked  User explicitly set it to block via the TUI
#   user_allowed  User allowed it via whitelist — daemon SKIPS the block
#
# Dependencies: log (log_warn), _validate_label (in main),
# globals ATM_BASE/ATM_DISABLED_FILE.

# State constants (exported for other lib modules).
typeset -gr ATM_DLIST_STATE_AUTO_BLOCKED="auto_blocked"
typeset -gr ATM_DLIST_STATE_USER_BLOCKED="user_blocked"
typeset -gr ATM_DLIST_STATE_USER_ALLOWED="user_allowed"

# === PB-04 (v4.15.0): In-memory state cache ===
# Hot-path optimization: disabled_list_get_state was called ~20× per block_action
# (1× per launchd component + 1× per pluginkit bundle).
# Before: each call grep + head fork = ~4.4ms × 20 = ~88ms/tick.
# Now: the cache is reloaded once per file mutation, all lookups < 50μs.
#
# Cache key (analogous to the authority cache): inode:size:mtime.
# Detects a file replace even when the mtime was frozen via 'touch -t'.
#
# Performance-critical: zstat (zsh/stat module, builtin) instead of /usr/bin/stat —
# ~35μs vs. ~3000μs (fork cost). Soft fallback if the module is unavailable.
typeset -gA _DLIST_STATE_CACHE=()
typeset -g _DLIST_CACHE_KEY=""
typeset -g _DLIST_CACHE_FILE=""

# Lazy-load the zstat module (once per shell). Should be present on every zsh
# since 4.0, defensive in case of a custom build without zsh/stat.
zmodload -F zsh/stat b:zstat 2>/dev/null || true

# Refresh: load the cache from the file if the file identity has changed.
# Idempotent — no file I/O if the file is unchanged.
_disabled_list_cache_refresh() {
    # File path change (e.g. test reload with a different ATM_DISABLED_FILE) → hard reset
    if [[ "$ATM_DISABLED_FILE" != "$_DLIST_CACHE_FILE" ]]; then
        _DLIST_STATE_CACHE=()
        _DLIST_CACHE_KEY=""
        _DLIST_CACHE_FILE="$ATM_DISABLED_FILE"
    fi
    if [[ ! -f "$ATM_DISABLED_FILE" ]]; then
        # File gone → clear the cache (may have been populated before)
        if [[ -n "$_DLIST_CACHE_KEY" ]]; then
            _DLIST_STATE_CACHE=()
            _DLIST_CACHE_KEY=""
        fi
        return 0
    fi
    local key
    if (( ${+builtins[zstat]} )); then
        local -A _stat_info
        zstat -L -H _stat_info "$ATM_DISABLED_FILE" 2>/dev/null && \
            key="${_stat_info[inode]}:${_stat_info[size]}:${_stat_info[mtime]}"
    fi
    # Soft fallback: stat fork (slower, but always works)
    [[ -z "$key" ]] && key=$(/usr/bin/stat -f "%i:%z:%m" "$ATM_DISABLED_FILE" 2>/dev/null)
    [[ -z "$key" ]] && key="0:0:0"
    [[ "$key" == "$_DLIST_CACHE_KEY" ]] && return 0   # Cache fresh
    # Reload
    _DLIST_STATE_CACHE=()
    local lbl scope ts state
    while IFS=$'\t' read -r lbl scope ts state; do
        [[ -z "$lbl" ]] && continue
        # Lazy-migrate 3-col (legacy): empty state → auto_blocked.
        # Identical behavior to disabled_list_get_state before.
        [[ -z "$state" ]] && state="auto_blocked"
        _DLIST_STATE_CACHE[$lbl]="$state"
    done < "$ATM_DISABLED_FILE"
    _DLIST_CACHE_KEY="$key"
    return 0
}

# Explicit invalidation — for callers that are writing the file right now.
# Saves 1 stat call on the next get_state.
_disabled_list_cache_invalidate() {
    _DLIST_STATE_CACHE=()
    _DLIST_CACHE_KEY=""
}

# State validation (shared by add/set).
_dlist_validate_state() {
    case "${1-}" in
        auto_blocked|user_blocked|user_allowed) return 0 ;;
        *) return 1 ;;
    esac
}

disabled_list_read() {
    [[ -f "$ATM_DISABLED_FILE" ]] || return 0
    /bin/cat -- "$ATM_DISABLED_FILE"
}

# disabled_list_add <label> <scope> [state]
# state default = auto_blocked. Idempotent: an existing entry is NOT
# overwritten (use disabled_list_set_state for updates).
disabled_list_add() {
    local label="$1" scope="$2" state="${3:-auto_blocked}"
    [[ -z "$label" || -z "$scope" ]] && return 2
    if ! _validate_label "$label"; then
        log_warn "disabled_list_add: invalid label rejected: '${label}'"
        return 2
    fi
    case "$scope" in
        gui|user|system) ;;
        *) log_warn "disabled_list_add: invalid scope: '${scope}'"; return 2 ;;
    esac
    if ! _dlist_validate_state "$state"; then
        log_warn "disabled_list_add: invalid state: '${state}'"
        return 2
    fi
    [[ -d "$ATM_BASE" ]] || /bin/mkdir -p "$ATM_BASE" || return 1
    /usr/bin/touch "$ATM_DISABLED_FILE"
    # Idempotency: skip if the label already exists
    if /usr/bin/grep -q -- "^${label}"$'\t' "$ATM_DISABLED_FILE" 2>/dev/null; then
        return 0
    fi
    local ts
    ts=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
    print -- "${label}\t${scope}\t${ts}\t${state}" >> "$ATM_DISABLED_FILE"
}

# disabled_list_remove <label> — removes the entry completely
disabled_list_remove() {
    local label="$1"
    [[ -z "$label" ]] && return 2
    [[ -f "$ATM_DISABLED_FILE" ]] || return 0
    local tmp="$ATM_DISABLED_FILE.tmp.$$"
    /usr/bin/grep -v -- "^${label}"$'\t' "$ATM_DISABLED_FILE" > "$tmp" 2>/dev/null || true
    /bin/mv -f "$tmp" "$ATM_DISABLED_FILE"
}

disabled_list_clear() {
    [[ -d "$ATM_BASE" ]] || return 0
    : > "$ATM_DISABLED_FILE"
}

# disabled_list_get_state <label> → stdout state (auto_blocked|user_blocked|user_allowed) or empty
# Return: 0 if found, 1 if not
# Lazy migration: 3-col entry (legacy) → state=auto_blocked
#
# PB-04 (v4.15.0): cache-backed. Before, 1× grep + 1× head fork per call
# (~4.4ms). Now an O(1) lookup after the mtime-keyed cache refresh.
disabled_list_get_state() {
    local label="$1"
    [[ -z "$label" ]] && return 1
    _disabled_list_cache_refresh
    local state="${_DLIST_STATE_CACHE[$label]-}"
    [[ -z "$state" ]] && return 1
    print -- "$state"
    return 0
}

# disabled_list_set_state <label> <scope> <state>
# Update-or-add. For an existing entry the state column is overwritten
# (label/scope/disabled_at unchanged). For a new entry: fully initialized.
disabled_list_set_state() {
    local label="$1" scope="$2" state="$3"
    [[ -z "$label" || -z "$scope" || -z "$state" ]] && return 2
    if ! _validate_label "$label"; then
        log_warn "disabled_list_set_state: invalid label: '${label}'"
        return 2
    fi
    case "$scope" in
        gui|user|system) ;;
        *) log_warn "disabled_list_set_state: invalid scope: '${scope}'"; return 2 ;;
    esac
    if ! _dlist_validate_state "$state"; then
        log_warn "disabled_list_set_state: invalid state: '${state}'"
        return 2
    fi
    [[ -d "$ATM_BASE" ]] || /bin/mkdir -p "$ATM_BASE" || return 1
    /usr/bin/touch "$ATM_DISABLED_FILE"
    # If the label exists: rewrite; otherwise: append.
    if /usr/bin/grep -q -- "^${label}"$'\t' "$ATM_DISABLED_FILE" 2>/dev/null; then
        local tmp="$ATM_DISABLED_FILE.tmp.$$"
        local lbl s ts old_state
        : > "$tmp"
        while IFS=$'\t' read -r lbl s ts old_state; do
            if [[ "$lbl" == "$label" ]]; then
                [[ -z "$ts" ]] && ts=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
                print -- "${lbl}\t${s}\t${ts}\t${state}" >> "$tmp"
            else
                # Re-emit the existing line, lazy-migrate if 3-col
                [[ -z "$old_state" ]] && old_state="auto_blocked"
                print -- "${lbl}\t${s}\t${ts}\t${old_state}" >> "$tmp"
            fi
        done < "$ATM_DISABLED_FILE"
        /bin/mv -f "$tmp" "$ATM_DISABLED_FILE"
    else
        local ts
        ts=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
        print -- "${label}\t${scope}\t${ts}\t${state}" >> "$ATM_DISABLED_FILE"
    fi
}

# disabled_list_is_user_allowed <label> — exit 0 if state=user_allowed.
# Convenience wrapper for the block-action skip check (hot path).
#
# PB-04 (v4.15.0): direct cache lookup, NOT via $(disabled_list_get_state)
# — otherwise the subshell would have to reload the cache (4.4ms instead of μs),
# because zsh subshells have their own variable scopes.
disabled_list_is_user_allowed() {
    local label="$1"
    [[ -z "$label" ]] && return 1
    _disabled_list_cache_refresh
    [[ "${_DLIST_STATE_CACHE[$label]-}" == "user_allowed" ]]
}

# disabled_list_validate_integrity (v4.14.0+) — scan disabled.list, verify
# that all lines are 3-col (legacy) or 4-col (current). Logs every violation.
# Returns a BOOLEAN exit code: 0 = clean, 1 = dirty. The malformed-line count
# is exposed via the global _DLIST_MALFORMED_COUNT so callers that need the
# number can read it without the count-as-exit-code footgun (which wraps >255
# and breaks any boolean `if`-style caller). The count is NOT printed to stdout
# — the function is called inline by init_state, whose own stdout must stay
# clean.
# Field-counting uses native zsh splitting (${#${(s.\t.)line}}) — no per-line
# awk fork.
# Called by the daemon on init — defense-in-depth against subtle
# tampering or pre-v4.0 schema remnants.
typeset -gi _DLIST_MALFORMED_COUNT=0
disabled_list_validate_integrity() {
    _DLIST_MALFORMED_COUNT=0
    [[ -f "$ATM_DISABLED_FILE" ]] || return 0
    local -i malformed=0 line_no=0 nf
    local line
    while IFS= read -r line; do
        line_no=$(( line_no + 1 ))
        [[ -z "$line" ]] && continue   # tolerate empty lines
        # Native zsh tab-field count — splits $line on tabs, counts the parts.
        nf=${#${(s.	.)line}}
        if (( nf != 3 && nf != 4 )); then
            log_warn "disabled.list line $line_no: malformed (NF=$nf, expected 3 or 4): ${line:0:80}"
            malformed=$(( malformed + 1 ))
            continue
        fi
        # For 4-col: validate the state value
        if (( nf == 4 )); then
            local state="${line##*$'\t'}"
            if ! _dlist_validate_state "$state"; then
                log_warn "disabled.list line $line_no: invalid state '$state'"
                malformed=$(( malformed + 1 ))
            fi
        fi
    done < "$ATM_DISABLED_FILE"
    if (( malformed > 0 )); then
        log_warn "disabled.list integrity-check: $malformed malformed line(s) of $line_no total"
    fi
    _DLIST_MALFORMED_COUNT=$malformed
    (( malformed == 0 ))   # boolean exit: 0 = clean, 1 = dirty
}
