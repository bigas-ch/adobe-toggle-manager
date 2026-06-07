#!/bin/zsh
# === lib/discovery.zsh — Adobe discovery + block/allow actions ===
# Module responsibility: discovery of Adobe LaunchAgents/daemons + processes
# via codesign authority + plist scan; block/allow actions including TOCTOU-
# safe pre-action validation; authority cache.
#
# Dependencies:
#   - log (log_warn, log_error, log_event)
#   - state (access to counters _DAEMON_DISABLED, _DAEMON_KILLED, _DAEMON_LAST_*)
#   - disabled_list (disabled_list_add, disabled_list_clear)
#   - config (config_get for notifications)
#   - backend_registry (backend_dispatch pluginkit for additive v4.3.0 passes)
#   - _validate_label (defined in main)
#   - _launchctl (defined in main, hard-guard wrapper)
#   - Global ADOBE_AUTHORITY_REGEX, ATM_DISABLED_FILE, ATM_DISCOVERED_FILE,
#     ATM_BASE, _BACKENDS_AVAILABLE

# === Discovery ===
# Default directories — overridable in tests via ATM_PLIST_DIRS
typeset -ga ATM_PLIST_DIRS_DEFAULT=(
    "/Library/LaunchDaemons"
    "/Library/LaunchAgents"
    "$HOME/Library/LaunchAgents"
)

# Authority cache (daemon-local, lives for the daemon lifetime).
# Cache hardening against TOCTOU (Finding C-2):
# - Key covers inode + size + mtime (not just mtime) → detects file replacement
#   even when mtime was frozen via 'touch -t'.
# - Cache entry = "auth_string|cached_at_ts" → 60-s TTL forces a refresh.
typeset -gA _AUTHORITY_CACHE=()
typeset -gri AUTH_CACHE_TTL=60

# v4.14.0 (S-02): background cleanup for expired entries.
# Called by the daemon per tick — removes entries older than the TTL.
# Without cleanup, entries would stay in the cache forever (RAM growth over
# a long daemon runtime, because the cache is only checked on write/on hit,
# never actively for stale entries).
_authority_cache_cleanup_expired() {
    local now=$EPOCHSECONDS
    local key entry cached_ts
    local -i evicted=0
    for key in "${(@k)_AUTHORITY_CACHE}"; do
        entry="${_AUTHORITY_CACHE[$key]}"
        cached_ts="${entry##*|}"
        if (( now - cached_ts >= AUTH_CACHE_TTL )); then
            unset "_AUTHORITY_CACHE[$key]"
            evicted=$(( evicted + 1 ))
        fi
    done
    return 0
}

# v4.14.0 (P-01): persist the authority cache to disk.
# Format: TSV with 2 columns: key\tvalue (value already contains "auth\tid|ts").
# At daemon start: load (immediate cache-warm phase, ~80% faster first tick).
# Periodically: save (every 10 ticks). Plus on EXIT (see daemon_main).
typeset -g ATM_AUTHORITY_CACHE_FILE="${ATM_AUTHORITY_CACHE_FILE:-$ATM_BASE/authority_cache.tsv}"

_authority_cache_save() {
    [[ -d "$ATM_BASE" ]] || return 0
    [[ -z "${(k)_AUTHORITY_CACHE}" ]] && return 0   # empty cache → no write
    local tmp="$ATM_AUTHORITY_CACHE_FILE.tmp.$$"
    local key
    : > "$tmp" || return 1
    for key in "${(@k)_AUTHORITY_CACHE}"; do
        # A NUL byte or TAB in the key would violate the format — skip defensively
        [[ "$key" == *$'\t'* ]] && continue
        # Atomic newline-separated TSV: "<key>\t<value>"
        # value already contains TAB+pipe — encoded as-is for an identical re-read.
        # A newline in the value would violate the format — codesign output contains no newlines.
        printf '%s\t%s\n' "$key" "${_AUTHORITY_CACHE[$key]}" >> "$tmp"
    done
    /bin/mv -f "$tmp" "$ATM_AUTHORITY_CACHE_FILE" 2>/dev/null || /bin/rm -f "$tmp"
}

_authority_cache_load() {
    [[ -f "$ATM_AUTHORITY_CACHE_FILE" ]] || return 0
    local now=$EPOCHSECONDS
    local key value cached_ts
    local -i loaded=0 expired=0
    while IFS=$'\t' read -r key value; do
        [[ -z "$key" || -z "$value" ]] && continue
        cached_ts="${value##*|}"
        # On load: do not even take over expired entries
        if [[ "$cached_ts" == <-> ]] && (( now - cached_ts < AUTH_CACHE_TTL )); then
            _AUTHORITY_CACHE[$key]="$value"
            loaded=$(( loaded + 1 ))
        else
            expired=$(( expired + 1 ))
        fi
    done < "$ATM_AUTHORITY_CACHE_FILE"
    if (( loaded > 0 || expired > 0 )); then
        # E-05 (v4.17.0): structured fields instead of string flattening
        log_event_structured AUTH_CACHE_LOAD "loaded=${loaded}" "expired=${expired}"
    fi
    return 0
}

_plist_scope() {
    local dir="$1"
    case "$dir" in
        */LaunchDaemons*) print -- "system" ;;
        "$HOME"/Library/LaunchAgents*) print -- "user" ;;
        */LaunchAgents*) print -- "gui" ;;
        *)
            # Test override: arbitrary paths can be used in tests
            case "$dir" in
                *LaunchDaemons*) print -- "system" ;;
                *UserLA*) print -- "user" ;;
                *LaunchAgents*) print -- "gui" ;;
                *) print -- "unknown" ;;
            esac
            ;;
    esac
}

# PB-06 (v4.15.0): mtime-keyed label cache for PlistBuddy lookups.
# Adobe plists almost never change their label — only app updates install new
# plists (old ones stay, new ones are added). Cache hit-rate >99%.
# Cache key: inode:size:mtime per plist path (analogous to PB-04 disabled-list).
# IMPORTANT: the cache lives INLINE in discover_plists (no separate $() wrapper),
# because every subshell wrap would lose the global cache mutations
# (see subshell trap in PB-04/PB-05).
typeset -gA _PLIST_LABEL_CACHE=()       # plist_path → label
typeset -gA _PLIST_LABEL_CACHE_KEYS=()  # plist_path → "inode:size:mtime"

discover_plists() {
    local -a dirs
    if (( ${#ATM_PLIST_DIRS[@]} > 0 )) 2>/dev/null; then
        dirs=( "${ATM_PLIST_DIRS[@]}" )
    else
        dirs=( "${ATM_PLIST_DIRS_DEFAULT[@]}" )
    fi
    local d plist label scope key
    local -A _stat_info
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for plist in "$d"/com.adobe*.plist(.N); do
            # PB-06: cache key via zstat (builtin) instead of /usr/bin/stat fork
            key=""
            if (( ${+builtins[zstat]} )); then
                _stat_info=()
                zstat -L -H _stat_info "$plist" 2>/dev/null && \
                    key="${_stat_info[inode]}:${_stat_info[size]}:${_stat_info[mtime]}"
            fi
            [[ -z "$key" ]] && key=$(/usr/bin/stat -f "%i:%z:%m" "$plist" 2>/dev/null)
            [[ -z "$key" ]] && key="0:0:0"
            # Cache hit?
            if [[ "${_PLIST_LABEL_CACHE_KEYS[$plist]-}" == "$key" ]]; then
                label="${_PLIST_LABEL_CACHE[$plist]}"
            else
                # Cache miss: fork PlistBuddy + store the result
                label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null)
                _PLIST_LABEL_CACHE[$plist]="$label"
                _PLIST_LABEL_CACHE_KEYS[$plist]="$key"
            fi
            # Label validation (C-3): only allow com.adobe* + safe chars.
            # Prevents TSV injection (tab/newline) and shell special chars
            # in launchctl calls.
            if ! _validate_label "$label"; then
                [[ -n "$label" ]] && log_warn "discover_plists: invalid label rejected: '${label}' (plist: $plist)"
                continue
            fi
            scope=$(_plist_scope "$d")
            print -- "launchd\t${label}\t${plist}\t${scope}"
        done
    done
}

# Fresh authority check WITHOUT cache — for pre-kill/pre-bootstrap validation.
# Prevents TOCTOU: between discovery (cached) and a destructive action an
# attacker could swap the binary. Before kill/bootstrap it must be re-checked
# freshly that the target is still Adobe-signed.
_codesign_authority_fresh() {
    local binary="$1"
    [[ -e "$binary" ]] || { print -- ""; return 1; }
    ${ATM_CODESIGN_BIN} -dvv "$binary" 2>&1 | /usr/bin/awk -F= '/^Authority=/ {print $2; exit}'
}

# (A cached authority check exists further below as _codesign_authority,
# implemented via a wrapper around _codesign_auth_and_id.)

# Out-variables for codesign results. No stdout output → no subshell
# wrapper needed → the cache (typeset -gA _AUTHORITY_CACHE)
# stays persistent in the current shell scope.
typeset -g _CODESIGN_AUTH=""
typeset -g _CODESIGN_ID=""

# A single codesign call extracts authority + identifier in one step.
# Cached via _AUTHORITY_CACHE (key = binary:inode:size:mtime, TTL 60 s).
# Output: sets $_CODESIGN_AUTH and $_CODESIGN_ID. NO print/stdout!
# return 0 = success, 1 = binary missing.
_codesign_auth_and_id() {
    local binary="$1"
    _CODESIGN_AUTH=""
    _CODESIGN_ID=""
    [[ -e "$binary" ]] || return 1
    local stat_str key now entry cached cached_ts
    # PB-07 (v4.15.0): zstat builtin (zsh/stat) instead of /usr/bin/stat fork.
    # Hot path during Adobe process discovery — per discover_processes run
    # _codesign_auth_and_id is called for every Adobe PID.
    # zstat: ~35μs vs /usr/bin/stat: ~3000μs (~80× speedup).
    stat_str=""
    if (( ${+builtins[zstat]} )); then
        local -A _stat_info
        zstat -L -H _stat_info "$binary" 2>/dev/null && \
            stat_str="${_stat_info[inode]}:${_stat_info[size]}:${_stat_info[mtime]}"
    fi
    [[ -z "$stat_str" ]] && stat_str=$(/usr/bin/stat -f "%i:%z:%m" "$binary" 2>/dev/null)
    [[ -z "$stat_str" ]] && stat_str="0:0:0"
    key="${binary}::${stat_str}"
    now=$EPOCHSECONDS   # PB-08: builtin instead of /bin/date +%s
    if [[ -n "${_AUTHORITY_CACHE[$key]+_}" ]]; then
        entry="${_AUTHORITY_CACHE[$key]}"
        cached_ts="${entry##*|}"
        if (( now - cached_ts < AUTH_CACHE_TTL )); then
            cached="${entry%|*}"
            _CODESIGN_AUTH="${cached%%$'\t'*}"
            _CODESIGN_ID="${cached#*$'\t'}"
            return 0
        fi
        unset "_AUTHORITY_CACHE[$key]"
    fi
    # Single codesign call — parse both values from ONE output
    local out
    out=$(${ATM_CODESIGN_BIN} -dvv "$binary" 2>&1)
    _CODESIGN_AUTH=$(print -- "$out" | /usr/bin/awk -F= '/^Authority=/ {print $2; exit}')
    _CODESIGN_ID=$(print -- "$out" | /usr/bin/awk -F= '/^Identifier=/ {print $2; exit}')
    _AUTHORITY_CACHE[$key]="${_CODESIGN_AUTH}"$'\t'"${_CODESIGN_ID}|${now}"
    return 0
}

# Backward compat (for paths that only need the authority, e.g. via stdout/$()).
# This variant uses $() → subshell cache loss on call, so use it only in
# non-hot paths.
_codesign_authority() {
    local binary="$1"
    _codesign_auth_and_id "$binary" || return 1
    print -- "$_CODESIGN_AUTH"
}

# _codesign_authority_fresh stays unchanged (defined further above) — bypasses the cache.

discover_processes() {
    # Pre-filter: only PIDs with Adobe-suspicious paths in comm.
    # Output: process\t<bundle-id>\tpid:<pid>\t<binary-path>
    # IMPORTANT: process substitution + direct function call WITHOUT $() —
    # otherwise the subshell trap: _AUTHORITY_CACHE modifications are lost.
    local pid binary auth ident
    while IFS=$'\t' read -r pid binary; do
        [[ -n "$pid" && -n "$binary" ]] || continue
        # Direct call — out-variables _CODESIGN_AUTH/_CODESIGN_ID
        # are set in the current scope (no $() wrapper!)
        _codesign_auth_and_id "$binary" || continue
        auth="$_CODESIGN_AUTH"
        ident="$_CODESIGN_ID"
        if [[ "$auth" =~ $ADOBE_AUTHORITY_REGEX ]]; then
            [[ -z "$ident" ]] && ident="$binary"
            print -- "process\t${ident}\tpid:${pid}\t${binary}"
        fi
    done < <(/bin/ps -axo pid=,comm= 2>/dev/null | /usr/bin/awk '
        $2 ~ /\/Adobe/ ||
        $2 ~ /Creative Cloud/ ||
        $2 ~ /\/Library\/Application Support\/Adobe/ {
            pid=$1
            $1=""
            sub(/^[ \t]+/, "")
            print pid "\t" $0
        }
    ')
}

discovery_sweep() {
    [[ -d "$ATM_BASE" ]] || /bin/mkdir -p "$ATM_BASE"
    {
        discover_plists
        discover_processes
    } > "$ATM_DISCOVERED_FILE"
    local n
    n=$(/usr/bin/wc -l < "$ATM_DISCOVERED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    log_event DISCOVERY_RUN "${n:-0}"
}

# === PB-02/03 (v4.15.0): reuse discovered.list instead of re-discovering ===
# discovery_sweep writes discovered.list in the same tick with BOTH plists and
# processes. block_action + kill_adobe_processes can filter from it instead of
# running discover_plists/discover_processes again (~95ms + 45ms saved
# per tick). Soft fallback to live discovery if the file is missing (test
# contexts or the first daemon tick before the first discovery_sweep call).
#
# Format recap: every line begins with a type prefix (launchd|process|...) + TAB.
_read_discovered_by_type() {
    local target_type="$1"
    if [[ -f "$ATM_DISCOVERED_FILE" ]]; then
        /usr/bin/grep "^${target_type}"$'\t' "$ATM_DISCOVERED_FILE" 2>/dev/null
        return 0
    fi
    # Fallback: live discovery (slow, but safe for tests + cold start)
    case "$target_type" in
        launchd) discover_plists ;;
        process) discover_processes ;;
        *) return 1 ;;
    esac
}

# === Notifications — extracted into lib/notify.zsh (v4.4.0) ===
[[ -f "$ATM_LIB_DIR/notify.zsh" ]] && source "$ATM_LIB_DIR/notify.zsh"

# === Action: Block ===
# Pre-kill authority check: before every `kill` the authority is re-validated
# FRESH (no cache). Prevents TOCTOU between discovery and kill.
# If the authority is no longer Adobe or the binary is gone → kill skip + WARN log.
_validate_kill_target() {
    local pid="$1" expected_ident="$2" binary="$3"
    [[ -z "$pid" || ! "$pid" == <-> ]] && return 1
    [[ -z "$binary" || ! -e "$binary" ]] && {
        log_warn "kill skipped: binary missing for pid=$pid (${expected_ident})"
        return 1
    }
    local auth_fresh
    auth_fresh=$(_codesign_authority_fresh "$binary")
    if [[ ! "$auth_fresh" =~ $ADOBE_AUTHORITY_REGEX ]]; then
        log_warn "kill skipped: authority mismatch for pid=$pid (${expected_ident}) — got '${auth_fresh}'"
        return 1
    fi
    return 0
}

kill_adobe_processes() {
    local _type ident src binary pid
    local term_count=0 kill_count=0
    # PB-03 (v4.15.0): the TERM loop reads from discovered.list (fresh from
    # discovery_sweep). Saves 1× discover_processes (~45ms). The KILL loop below
    # STAYS on live discover_processes — after TERM+sleep new Adobe processes
    # may have started (FSEvents) OR old ones ended; a fresh PID list is
    # essential for correct KILL targeting.
    while IFS=$'\t' read -r _type ident src binary; do
        pid="${src#pid:}"
        _validate_kill_target "$pid" "$ident" "$binary" || continue
        if kill -TERM "$pid" 2>/dev/null; then
            log_event KILLED "${ident}:${pid}:TERM"
            term_count=$(( term_count + 1 ))
            _DAEMON_LAST_KILL="$(/bin/date +%H:%M:%S)|${ident}:${pid}"
        fi
    done < <(_read_discovered_by_type process)
    # QW-5 (v4.15.x): only re-discover + run the KILL loop when the TERM loop
    # actually TERM'd something. In steady state (no Adobe processes) term_count
    # is 0, so the live discover_processes (ps+awk fork + per-PID codesign) and
    # its empty KILL loop are pure waste. When something WAS TERM'd we still need
    # a fresh PID list after the grace sleep (some may have exited, new ones may
    # have started via FSEvents) — behavior there is unchanged.
    if (( term_count > 0 )); then
        /bin/sleep 2
        while IFS=$'\t' read -r _type ident src binary; do
            pid="${src#pid:}"
            _validate_kill_target "$pid" "$ident" "$binary" || continue
            if kill -KILL "$pid" 2>/dev/null; then
                log_event KILLED "${ident}:${pid}:KILL"
                kill_count=$(( kill_count + 1 ))
            fi
        done < <(discover_processes)
    fi
    _DAEMON_KILLED=$(( _DAEMON_KILLED + term_count + kill_count ))
}

disable_launchd_label() {
    local label="$1" scope="$2"
    # Defense in depth: label validation here too (C-3).
    if ! _validate_label "$label"; then
        log_warn "disable_launchd_label: invalid label rejected: '${label}'"
        return 1
    fi
    # v4.8.0: whitelist check (user explicitly marked the component as user_allowed).
    # The daemon respects user intent and does NOT block, even if global state=block.
    if disabled_list_is_user_allowed "$label" 2>/dev/null; then
        return 0
    fi
    case "$scope" in
        gui|user)
            local target="${scope}/${UID}/${label}"
            # Skip if already in disabled.list (idempotency — otherwise the counter is incremented per tick)
            if [[ -f "$ATM_DISABLED_FILE" ]] && /usr/bin/grep -q -- "^${label}"$'\t' "$ATM_DISABLED_FILE" 2>/dev/null; then
                return 0
            fi
            _launchctl bootout "$target" 2>/dev/null || true
            _launchctl disable "$target" 2>/dev/null
            disabled_list_add "$label" "$scope"
            log_event DISABLED "${label}:${scope}"
            _DAEMON_DISABLED=$(( _DAEMON_DISABLED + 1 ))
            _DAEMON_LAST_DISABLE="$(/bin/date +%H:%M:%S)|${label}:${scope}"
            ;;
        system)
            # LOG-1 (v4.1.1): idempotency check analogous to the gui|user path above.
            # Without this skip, WARN_NEEDS_SUDO is re-emitted on every daemon tick
            # (every 30s) for each system label — a live system had
            # 1565 WARN lines in 1 day with 4 system labels. If the label
            # is already in disabled.list (from the on-demand sudo sweep of the TUI),
            # another WARN is not new information. Drift against
            # the disabled state is captured by the separate DRIFT_DETECTED
            # mechanism, not here.
            if [[ -f "$ATM_DISABLED_FILE" ]] && /usr/bin/grep -q -- "^${label}"$'\t' "$ATM_DISABLED_FILE" 2>/dev/null; then
                return 0
            fi
            log_event WARN_NEEDS_SUDO "$label"
            log_warn "system-launchd label '$label' requires sudo, skipping in daemon"
            ;;
        *)
            log_warn "unknown scope '$scope' for label '$label', skipping"
            ;;
    esac
}

block_action() {
    local _type label _plist scope
    # PB-02 (v4.15.0): read from discovered.list (written fresh by discovery_sweep
    # in the same tick) instead of running discover_plists again.
    # Process substitution instead of a pipe — otherwise the subshell trap:
    # counter updates in disable_launchd_label would be lost.
    while IFS=$'\t' read -r _type label _plist scope; do
        disable_launchd_label "$label" "$scope"
    done < <(_read_discovered_by_type launchd)
    kill_adobe_processes
    # v4.3.0 additive: pluginkit backend (if registered).
    # The launchd behavior above is UNCHANGED — pluginkit comes in addition.
    # v4.8.0: whitelist skip for pluginkit items too (same disabled.list state).
    if (( _BACKENDS_AVAILABLE )) && backend_is_registered pluginkit 2>/dev/null; then
        local pl_type pl_id pl_scope pl_path
        backend_dispatch pluginkit discover 2>/dev/null \
            | while IFS=$'\t' read -r pl_type pl_id pl_scope pl_path; do
                [[ -z "$pl_id" ]] && continue
                # Skip if the user marked the bundle ID as user_allowed
                if disabled_list_is_user_allowed "$pl_id" 2>/dev/null; then
                    continue
                fi
                backend_dispatch pluginkit block "$pl_type" "$pl_id" "$pl_scope" "$pl_path" 2>/dev/null
            done
        backend_dispatch pluginkit kill_running 2>/dev/null
    fi
}

# === Action: Allow ===
# Allowed plist directories for bootstrap (TOCTOU protection).
# The realpath of the plist path MUST lie under one of these prefixes.
typeset -gra _ALLOWED_PLIST_PREFIXES=(
    "/Library/LaunchAgents/"
    "/Library/LaunchDaemons/"
    "$HOME/Library/LaunchAgents/"
)

# Validates a plist path for bootstrap: must exist, be a regular file, and its
# realpath must lie under an allowed prefix. Prevents a plist smuggled in via
# a symlink race or path traversal from being bootstrapped.
_validate_plist_path() {
    local plist="$1"
    [[ -f "$plist" ]] || return 1
    # v4.1.1 SEC-4 fix: macOS ships realpath at /bin/realpath, not /usr/bin/realpath.
    # Previous /usr/bin/realpath call ALWAYS failed → ALL plists rejected
    # → 'launchctl bootstrap' was never called in allow_action → Adobe services
    # were never actively re-registered after Allow.
    # Use zsh-builtin ${plist:A} (resolve symlinks + absolute) — no external dep,
    # always available, L-2-conform.
    local real="${plist:A}"
    [[ -f "$real" ]] || return 1
    local prefix
    for prefix in "${_ALLOWED_PLIST_PREFIXES[@]}"; do
        [[ "$real" == "$prefix"* ]] && return 0
    done
    log_warn "plist path outside allowed prefixes: $plist (real: $real)"
    return 1
}

enable_launchd_label() {
    local label="$1" scope="$2"
    case "$scope" in
        gui|user)
            local target="${scope}/${UID}/${label}"
            _launchctl enable "$target" 2>/dev/null
            # bootstrap only if the plist still exists AND the path is validated
            local plist="$HOME/Library/LaunchAgents/${label}.plist"
            [[ "$scope" == gui ]] && plist="/Library/LaunchAgents/${label}.plist"
            if _validate_plist_path "$plist"; then
                _launchctl bootstrap "${scope}/${UID}" "$plist" 2>/dev/null || true
            fi
            log_event ENABLED "${label}:${scope}"
            ;;
        system)
            log_event WARN_NEEDS_SUDO "enable-$label"
            log_warn "system-launchd label '$label' requires /usr/bin/sudo for enable, skipping"
            ;;
    esac
}

allow_action() {
    local label scope ts state
    local pending_system=0
    if [[ -f "$ATM_DISABLED_FILE" ]]; then
        # v4.8.0: 4-column format (label\tscope\tdisabled_at\tstate). Lazy migration:
        # 3-col legacy entries → state=auto_blocked (handled as before).
        # user_allowed entries are NOT enabled and NOT removed — user intent
        # stays persistent. user_blocked + auto_blocked are enabled + removed.
        local tmp="$ATM_DISABLED_FILE.tmp.$$"
        : > "$tmp"
        while IFS=$'\t' read -r label scope ts state; do
            # H-1: the TSV re-read is UNTRUSTED — re-validate label + scope.
            [[ -z "$label" ]] && continue
            if ! _validate_label "$label"; then
                log_warn "allow_action: invalid label in disabled.list rejected: '${label}'"
                continue
            fi
            case "$scope" in
                gui|user|system) ;;
                *) log_warn "allow_action: invalid scope '${scope}' for label '${label}'"; continue ;;
            esac
            [[ -z "$state" ]] && state="auto_blocked"   # legacy lazy migration
            if [[ "$state" == "user_allowed" ]]; then
                # Keep — the user explicitly wanted to allow the component.
                print -- "${label}\t${scope}\t${ts}\t${state}" >> "$tmp"
                continue
            fi
            # v4.19.0 PHANTOM-FIX (C): the user-mode daemon cannot enable
            # scope=system (enable_launchd_label is a no-op for system, needs
            # TUI [e] + sudo_unsweep_action with Touch ID). The entry MUST stay
            # in disabled.list, otherwise a phantom state arises: the tool thinks
            # it is clean, the /bin/launchctl state is still disabled → Adobe CC
            # breaks with license errors without a visible tool hint.
            # Collect the counter, log once at the end — prevents LOG-1 spam
            # (4 system items × 30s tick = 11k warnings/day would be the result
            # of a naive per-item log).
            if [[ "$scope" == "system" ]]; then
                pending_system=$(( pending_system + 1 ))
                print -- "${label}\t${scope}\t${ts}\t${state}" >> "$tmp"
                continue
            fi
            # auto_blocked + user_blocked (only gui|user): enable + drop from disabled.list
            enable_launchd_label "$label" "$scope"
        done < "$ATM_DISABLED_FILE"
        /bin/mv -f "$tmp" "$ATM_DISABLED_FILE"
    fi
    # v4.19.0 (C): persist the pending counter for TUI status + 1× WARN log
    # per allow_action run (not per tick, not per item).
    _DAEMON_PENDING_SYSTEM=$pending_system
    if (( pending_system > 0 )); then
        log_event WARN_NEEDS_SUDO "allow_pending_system_count=${pending_system}"
    fi
    # v4.3.0 additive: pluginkit backend allow.
    # The launchd behavior above is UNCHANGED — pluginkit comes in addition.
    # The pluginkit state lives in the pluginkit DB (not disabled.list), so
    # we iterate over backend discovery + use is_blocked as a filter.
    if (( _BACKENDS_AVAILABLE )) && backend_is_registered pluginkit 2>/dev/null; then
        local pl_type pl_id pl_scope pl_path
        backend_dispatch pluginkit discover 2>/dev/null \
            | while IFS=$'\t' read -r pl_type pl_id pl_scope pl_path; do
                [[ -z "$pl_id" ]] && continue
                if backend_dispatch pluginkit is_blocked "$pl_type" "$pl_id" "$pl_scope" "$pl_path" 2>/dev/null; then
                    backend_dispatch pluginkit allow "$pl_type" "$pl_id" "$pl_scope" "$pl_path" 2>/dev/null
                fi
            done
    fi
    # Optional: Auto-Start CC
    if [[ "$(config_get auto-start-cc 2>/dev/null)" == "true" ]]; then
        /usr/bin/open -a "Creative Cloud" 2>/dev/null
    fi
}
