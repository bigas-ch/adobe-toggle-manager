#!/bin/zsh
# === lib/watcher.zsh — FSEvents watcher lifecycle (v4.5.0) ===
# Module responsibility: spawn/stop of the atm-watcher Swift binary (FSEventStream).
# On every file event in the watched paths the watcher sends SIGUSR1 to the
# daemon PID — the daemon loop interrupts the safety-tick sleep + tick immediately.
#
# Soft fallback: if the binary is missing (e.g. xcode-tools not installed
# at build time), _watcher_start returns exit 1 and the daemon falls back
# to the existing 30s polling.
#
# Dependencies: log (log_warn, log_event), global ATM_BASE.
# Consumers: lib/daemon.zsh.

# v4.5.1: path resolution for the watcher in this order:
#   1. ATM_WATCHER_BIN (override) — if set + executable, use as binary.
#      Required for tests (mock_atm_watcher).
#   2. $ATM_BASE/atm-watcher — compiled binary (v4.5.0 mode, if it exists)
#   3. xcrun swift + .swift source (interpreter mode, default since v4.5.1)
#
# Background: compiled binaries with an ad-hoc signature get killed
# immediately in the LaunchAgent context (stricter library validation on
# macOS 14+) with "SIGKILL Code Signature Invalid". The Swift interpreter
# avoids this because swift-frontend is Apple-signed. Trade-off: ~1-2s startup cost.
typeset -g ATM_WATCHER_BIN="${ATM_WATCHER_BIN:-$ATM_BASE/atm-watcher}"
typeset -g ATM_WATCHER_SWIFT_SRC="${ATM_WATCHER_SWIFT_SRC:-$ATM_BASE/atm-watcher.swift}"

# Default watch paths (overridable in tests via ATM_WATCH_DIRS).
# v4.5.2: /Applications + /Library/Application Support/Adobe added to cover
# pluginkit-extension source paths. Adobe app updates install new/changed
# .appex files into /Applications/*/Contents/PlugIns/ or
# /Library/Application Support/Adobe/*/Contents/PlugIns/ — FSEvents on those
# triggers daemon-tick → block_action → pluginkit-extension-block.
#
# Manual `pluginkit -e use/ignore` calls write into the LaunchServices
# csstore (binary db under /private/var/folders/...) — that is not reliably
# watchable and is reconciled by the safety-tick interval (5 min).
typeset -ga ATM_WATCH_DIRS_DEFAULT=(
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    "$HOME/Library/LaunchAgents"
    "$HOME/Library/Application Support/Adobe"
    "/Applications"
    "/Library/Application Support/Adobe"
)

# PID of the running watcher subprocess (for _watcher_stop).
typeset -gi _ATM_WATCHER_PID=0

# v4.14.0 (S-01): pin file for the SHA-256 of atm-watcher.swift.
typeset -g ATM_WATCHER_HASH_FILE="${ATM_WATCHER_HASH_FILE:-$ATM_BASE/atm-watcher.sha256}"

# _watcher_validate_swift_hash — verifies $ATM_WATCHER_SWIFT_SRC matches
# the pinned hash. Returns 0 = ok, 1 = mismatch (refuse spawn).
# First run: writes the current hash as the pin (trust-on-first-use).
# Override: ATM_WATCHER_SKIP_HASH=1 for tests/emergencies.
_watcher_validate_swift_hash() {
    [[ "${ATM_WATCHER_SKIP_HASH:-0}" == "1" ]] && return 0
    [[ -f "$ATM_WATCHER_SWIFT_SRC" ]] || return 0   # no file → nothing to validate
    local current_hash pinned_hash
    current_hash=$(/usr/bin/shasum -a 256 "$ATM_WATCHER_SWIFT_SRC" 2>/dev/null | /usr/bin/awk '{print $1}')
    [[ -z "$current_hash" ]] && { log_warn "_watcher_validate_swift_hash: shasum failed"; return 0; }
    if [[ ! -f "$ATM_WATCHER_HASH_FILE" ]]; then
        # Trust-on-first-use: pin the current hash
        print -- "$current_hash" > "$ATM_WATCHER_HASH_FILE" 2>/dev/null
        log_event WATCHER_HASH_PINNED "$current_hash"
        return 0
    fi
    read -r pinned_hash < "$ATM_WATCHER_HASH_FILE" 2>/dev/null
    if [[ "$current_hash" != "$pinned_hash" ]]; then
        # E-05 (v4.17.0): structured fields instead of string flattening
        log_event_structured WATCHER_HASH_MISMATCH "expected=${pinned_hash}" "got=${current_hash}"
        return 1
    fi
    return 0
}

# === _watcher_start <daemon-pid> ===
# Spawns atm-watcher as a background subprocess. The PID is stored in
# _ATM_WATCHER_PID. Verification: wait 0.3s + kill -0 check.
#
# Returns:
#   0 = watcher started (PID in _ATM_WATCHER_PID)
#   1 = binary missing → fallback
#   2 = spawn failure → fallback
#   3 = invalid daemon-pid argument
_watcher_start() {
    local daemon_pid="$1"
    if [[ -z "$daemon_pid" || ! "$daemon_pid" == <-> ]]; then
        log_warn "_watcher_start: invalid daemon-pid '$daemon_pid'"
        return 3
    fi
    # Mode resolution: binary > swift-interpreter > fallback
    local -a watcher_cmd
    if [[ -x "$ATM_WATCHER_BIN" ]]; then
        watcher_cmd=( "$ATM_WATCHER_BIN" )
    elif [[ -f "$ATM_WATCHER_SWIFT_SRC" ]] && /usr/bin/xcrun --find swift >/dev/null 2>&1; then
        # v4.14.0 (S-01): hash-pinning of the .swift file before every spawn.
        # Threat: an attacker replaces atm-watcher.swift with malicious code
        # that then runs with the Apple-signed swift-frontend.
        # Protection: the SHA-256 of the file is pinned on the first successful
        # spawn in $ATM_BASE/atm-watcher.sha256. On every subsequent spawn it
        # is compared — on mismatch: refuse + log_error.
        if ! _watcher_validate_swift_hash; then
            log_error "_watcher_start: SHA-256 mismatch for $ATM_WATCHER_SWIFT_SRC — refuse spawn"
            return 1
        fi
        watcher_cmd=( /usr/bin/xcrun swift "$ATM_WATCHER_SWIFT_SRC" )
    else
        log_warn "_watcher_start: neither binary ($ATM_WATCHER_BIN) nor swift-source ($ATM_WATCHER_SWIFT_SRC) available"
        return 1
    fi
    local -a dirs
    if (( ${#ATM_WATCH_DIRS[@]} > 0 )) 2>/dev/null; then
        dirs=( "${ATM_WATCH_DIRS[@]}" )
    else
        dirs=( "${ATM_WATCH_DIRS_DEFAULT[@]}" )
    fi
    # Filter: only pass on existing directories (otherwise exit 3 from the binary).
    local -a existing_dirs
    local d
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] && existing_dirs+=( "$d" )
    done
    if (( ${#existing_dirs[@]} == 0 )); then
        log_warn "_watcher_start: no watch dirs exist"
        return 2
    fi
    # Paths as a ':'-separated string to the watcher
    local paths_arg="${(j.:.)existing_dirs}"
    # stderr into the daemon-err log (instead of /dev/null), for debugging crashes.
    # Ensure the logs directory exists — normally created by init_state,
    # but tests may call _watcher_start directly.
    [[ -d "$ATM_LOGS_DIR" ]] || /bin/mkdir -p "$ATM_LOGS_DIR" 2>/dev/null
    "${watcher_cmd[@]}" "$daemon_pid" "$paths_arg" \
        2>>"$ATM_LOGS_DIR/atm-watcher.err" &
    _ATM_WATCHER_PID=$!
    # Liveness check — the interpreter needs ~1-2s to compile (binary <0.1s).
    # We wait 2s so interpreter mode is not wrongly marked as crashed.
    /bin/sleep 2
    if ! kill -0 "$_ATM_WATCHER_PID" 2>/dev/null; then
        log_warn "_watcher_start: watcher crashed immediately (PID $_ATM_WATCHER_PID, mode=${watcher_cmd[1]:t})"
        _ATM_WATCHER_PID=0
        return 2
    fi
    log_event WATCHER_START "$_ATM_WATCHER_PID:${#existing_dirs[@]}_paths:${watcher_cmd[1]:t}"
    return 0
}

# === _watcher_stop ===
# Cleanly kills the watcher subprocess via SIGTERM (atm-watcher cleans up the
# FSEventStream + exit 0). Escalates to SIGKILL after 1s if SIGTERM has no effect.
_watcher_stop() {
    (( _ATM_WATCHER_PID > 0 )) || return 0
    kill -0 "$_ATM_WATCHER_PID" 2>/dev/null || { _ATM_WATCHER_PID=0; return 0; }
    /bin/kill -TERM "$_ATM_WATCHER_PID" 2>/dev/null
    /bin/sleep 1
    if kill -0 "$_ATM_WATCHER_PID" 2>/dev/null; then
        /bin/kill -KILL "$_ATM_WATCHER_PID" 2>/dev/null
        log_warn "_watcher_stop: had to KILL watcher (PID $_ATM_WATCHER_PID)"
    fi
    log_event WATCHER_STOP "$_ATM_WATCHER_PID"
    _ATM_WATCHER_PID=0
    return 0
}

# === _watcher_running ===
# Exit 0 if the watcher is active, otherwise 1.
_watcher_running() {
    (( _ATM_WATCHER_PID > 0 )) || return 1
    kill -0 "$_ATM_WATCHER_PID" 2>/dev/null
}
