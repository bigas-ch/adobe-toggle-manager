#!/bin/zsh
# === lib/daemon.zsh — headless daemon loop + summary + help ===
# Module responsibility: tick loop (state poll, block_action/allow_action,
# discovery_sweep, live_state_write), single-instance lock via PID file,
# signal handler (SIGUSR1 = immediate tick, SIGTERM = clean shutdown),
# subcommands summary_main + help_main.
#
# Dependencies: state, log, discovery (block_action/allow_action/discovery_sweep),
# config (config_get tick-interval), global APP_NAME/VERSION/LABEL, ATM_PID_FILE,
# ATM_BASE, ATM_DISCOVERED_FILE, ATM_LOGS_DIR, _DAEMON_TICKS/DISABLED/KILLED.

# === Daemon loop ===
typeset -g _DAEMON_TICK_NOW=0
typeset -g _DAEMON_RUNNING=1
# PG-01 (v4.16.0): PID of the background sleep job for signal-interruptible sleep.
# The trap handler kills this job on SIGUSR1/SIGTERM → wait returns immediately
# instead of waiting for the full safety-tick-interval.
typeset -g _DAEMON_SLEEP_PID=0

_daemon_signal_usr1() {
    _DAEMON_TICK_NOW=1
    # PG-01: kill the active sleep job (if present) → wait returns immediately
    (( _DAEMON_SLEEP_PID > 0 )) && kill "$_DAEMON_SLEEP_PID" 2>/dev/null
}
_daemon_signal_term() {
    _DAEMON_RUNNING=0
    # PG-01: same mechanism for clean shutdown
    (( _DAEMON_SLEEP_PID > 0 )) && kill "$_DAEMON_SLEEP_PID" 2>/dev/null
}

# Single-instance lock via PID file (Finding H-2).
# Prevents a manually started second --daemon from running alongside the
# LaunchAgent daemon (race conditions on state/live_state).
# The race window is small but present — pragmatically accepted for a user tool.
_acquire_daemon_lock() {
    [[ -d "$ATM_BASE" ]] || /bin/mkdir -p "$ATM_BASE" || return 1
    if [[ -f "$ATM_PID_FILE" ]]; then
        local existing_pid
        existing_pid=$(<"$ATM_PID_FILE" 2>/dev/null)
        if [[ "$existing_pid" == <-> ]] && kill -0 "$existing_pid" 2>/dev/null; then
            log_error "daemon already running with PID $existing_pid; exiting"
            return 1
        fi
        log_warn "removing stale PID file (PID=$existing_pid)"
    fi
    local tmp="$ATM_PID_FILE.tmp"
    print -- "$$" > "$tmp" || return 1
    /bin/mv -f "$tmp" "$ATM_PID_FILE" || return 1
    return 0
}

_release_daemon_lock() {
    [[ -f "$ATM_PID_FILE" ]] || return 0
    local our_pid
    our_pid=$(<"$ATM_PID_FILE" 2>/dev/null)
    [[ "$our_pid" == "$$" ]] && /bin/rm -f "$ATM_PID_FILE"
    # v4.1.1 SEC-1 fix: explicit return 0 — without this, the [[ ]] test
    # propagates exit 1 when the PID does not match (function ran correctly,
    # exit code was misleading for callers / EXIT-trap chains).
    return 0
}

# PD-01 (v4.16.0): daemon_main split into focused sub-functions.
# Before: 117 LOC monolithic. Now: 6 SoC-separated functions (each <30 LOC).
# Sub-functions are individually testable (see test_daemon_helpers.bats).

# Watcher state as a global var (was local, needed :-0 default in trap).
# Global → the trap handler is guaranteed access, no out-of-scope risk.
typeset -gi _DAEMON_WATCHER_ACTIVE=0

# _daemon_setup — lock + watcher spawn + trap setup + counter init + cache load.
# Returns 1 if lock acquisition fails (prevents double start).
_daemon_setup() {
    init_state
    _acquire_daemon_lock || return 1

    # Start the FSEvents watcher if available; on success switch to the
    # safety-tick-interval (event-driven), otherwise pure-polling tick.
    _DAEMON_WATCHER_ACTIVE=0
    if (( $+functions[_watcher_start] )); then
        _watcher_start "$$" 2>/dev/null && _DAEMON_WATCHER_ACTIVE=1
    fi

    # v4.19.3 (PD-04): do NOT set any traps in _daemon_setup anymore — in zsh a
    # `trap '...' SIG` inside a function is function-local (LOCAL_TRAPS is on
    # with `emulate -L zsh`) and is released again on function return.
    # This applied both to `trap '...' EXIT` (fired on setup return, killing
    # the freshly started watcher) and to `trap _daemon_signal_usr1 USR1`
    # and `trap _daemon_signal_term TERM INT` (gone after setup return →
    # default disposition: SIGUSR1/SIGTERM terminated the daemon hard →
    # KeepAlive restart bursts). All three traps are now set in daemon_main,
    # whose function lifetime = daemon lifetime.
    log_event_structured DAEMON_START "pid=${$}" "watcher_active=${_DAEMON_WATCHER_ACTIVE}"
    log_cleanup

    _DAEMON_TICKS=0
    _DAEMON_DISABLED=0
    _DAEMON_KILLED=0
    _DAEMON_LAST_DISABLE=""
    _DAEMON_LAST_KILL=""
    # E-06 (v4.18.0): adaptive-tick-interval state
    _DAEMON_QUIET_TICKS=0
    live_state_write
    (( ${+functions[_authority_cache_load]} )) && _authority_cache_load
    return 0
}

# === E-06 (v4.18.0): adaptive tick-interval ===
# Constants (typeset -gri for read-only globals).
typeset -gri DEFAULT_ADAPTIVE_QUIET_THRESHOLD=5    # Double once after 5 quiet ticks
typeset -gri DEFAULT_ADAPTIVE_MAX_INTERVAL=3600    # Hard cap at 1h (3600s)

# State (initial 0, set in _daemon_setup):
typeset -gi _DAEMON_QUIET_TICKS=0

# _daemon_track_drift_for_adaptive <disabled_count_before_action>
# Called after _daemon_run_action, before _daemon_periodic_maintenance.
# Increment/reset logic for the adaptive counter:
#   - DRIFT detected (delta > 0 OR FSEvent-triggered tick) → counter=0 (reset)
#   - QUIET tick (no delta, no FSEvent, i.e. natural timeout) → counter+1
#
# Args: $1 = _DAEMON_DISABLED value before _daemon_run_action
_daemon_track_drift_for_adaptive() {
    local disabled_before="${1:-0}"
    if (( _DAEMON_DISABLED > disabled_before )) || (( _DAEMON_TICK_NOW )); then
        _DAEMON_QUIET_TICKS=0
    else
        _DAEMON_QUIET_TICKS=$(( _DAEMON_QUIET_TICKS + 1 ))
    fi
}

# _daemon_resolve_interval — read tick/safety-tick-interval from config.
# stdout: numeric interval (always a sane fallback on missing/non-numeric config).
#
# E-06 (v4.18.0): if config adaptive-interval=true AND the watcher is active,
# the base interval is doubled per DEFAULT_ADAPTIVE_QUIET_THRESHOLD quiet ticks.
# Hard cap at DEFAULT_ADAPTIVE_MAX_INTERVAL (3600s = 1h).
# Reset on drift via _daemon_track_drift_for_adaptive.
#
# Adaptive is OPT-IN (default off) because:
#   - it only saves ~2-3sec CPU/day (marginal)
#   - it can increase drift latency to a max of 1h
#   - trade-off character — the user decides deliberately
_daemon_resolve_interval() {
    local base interval_key
    if (( _DAEMON_WATCHER_ACTIVE )); then
        interval_key="safety-tick-interval"
        base=$(config_get "$interval_key" 2>/dev/null)
        [[ -z "$base" ]] && base="$DEFAULT_SAFETY_TICK_INTERVAL"
    else
        interval_key="tick-interval"
        base=$(config_get "$interval_key" 2>/dev/null)
        [[ -z "$base" ]] && base="$DEFAULT_TICK_INTERVAL"
    fi
    # Guard: non-numeric config value → fall back to default
    [[ "$base" == <-> ]] || base="$DEFAULT_TICK_INTERVAL"

    # E-06: adaptive-mode check
    # Only active when opt-in AND the watcher is active (otherwise no drift trigger).
    local enabled
    enabled=$(config_get adaptive-interval 2>/dev/null)
    if [[ "$enabled" != "true" ]] || (( ! _DAEMON_WATCHER_ACTIVE )); then
        print -- "$base"
        return 0
    fi

    # Doublings calculation: integer division quiet_ticks / threshold.
    # Examples with threshold=5, base=300:
    #   quiet_ticks=4  → doublings=0 → 300s
    #   quiet_ticks=5  → doublings=1 → 600s
    #   quiet_ticks=15 → doublings=3 → 2400s
    #   quiet_ticks=30 → doublings=6 → cap at 3600s
    local doublings=$(( _DAEMON_QUIET_TICKS / DEFAULT_ADAPTIVE_QUIET_THRESHOLD ))
    local interval=$(( base * (1 << doublings) ))
    (( interval > DEFAULT_ADAPTIVE_MAX_INTERVAL )) && interval=$DEFAULT_ADAPTIVE_MAX_INTERVAL
    print -- "$interval"
}

# _daemon_run_action — discovery + block_action / lean_action / allow_action
# depending on state. lean mirrors block (needs a fresh discovery sweep first).
_daemon_run_action() {
    case "${1-}" in
        block) discovery_sweep; block_action ;;
        lean)  discovery_sweep; lean_action ;;
        allow) allow_action ;;
        *) log_warn "daemon: unknown state '${1-}', skipping tick" ;;
    esac
}

# _daemon_state_notify — emit the state-change desktop notification for a state.
# Extracted from daemon_main's loop so the per-state message is unit-testable
# (block=red, lean=yellow, allow=green). Unknown states emit nothing.
_daemon_state_notify() {
    case "${1-}" in
        block) notify "Adobe Toggle" "🔴 Adobe blocked" ;;
        lean)  notify "Adobe Toggle" "🟡 Adobe lean (bloat off)" ;;
        allow) notify "Adobe Toggle" "🟢 Adobe allowed" ;;
    esac
}

# _daemon_periodic_maintenance — log rotation + authority-cache mgmt.
# Called every tick, performs its own frequency checks.
_daemon_periodic_maintenance() {
    # Log cleanup ~hourly (at 30s tick = every 120 ticks)
    (( _DAEMON_TICKS % 120 == 0 )) && log_cleanup
    # v4.14.0 S-02: authority-cache TTL cleanup every tick (~5ms)
    (( ${+functions[_authority_cache_cleanup_expired]} )) && _authority_cache_cleanup_expired
    # v4.14.0 P-01: persist the authority cache periodically (every 10 ticks)
    if (( _DAEMON_TICKS % 10 == 0 )) && (( ${+functions[_authority_cache_save]} )); then
        _authority_cache_save
    fi
}

# v4.19.3 (PD-04): check watcher liveness every tick.
# If the watcher dies post-startup (e.g. xcrun swift crash, Apple update,
# FSEvents permission drop), _DAEMON_WATCHER_ACTIVE must not stay 1 — otherwise
# the daemon stays on the safety-tick-interval (300s) instead of the
# normal tick (30s) and reports itself as unhealthy in the healthcheck.
# Defense in depth, analogous to the PD-04 trap fix.
_daemon_check_watcher_liveness() {
    (( _DAEMON_WATCHER_ACTIVE )) || return 0
    (( ${+functions[_watcher_running]} )) || return 0
    if ! _watcher_running; then
        log_warn "watcher died post-startup — falling back to normal-tick"
        _DAEMON_WATCHER_ACTIVE=0
    fi
}

# _daemon_interruptible_sleep <interval> — PG-01-Pattern.
# 1 fork pro Tick (statt 300×sleep 1). Trap killt _DAEMON_SLEEP_PID, wait returnt sofort.
_daemon_interruptible_sleep() {
    if (( _DAEMON_RUNNING && ! _DAEMON_TICK_NOW )); then
        /bin/sleep "$1" &
        _DAEMON_SLEEP_PID=$!
        wait "$_DAEMON_SLEEP_PID" 2>/dev/null
        _DAEMON_SLEEP_PID=0
    fi
    _DAEMON_TICK_NOW=0
}

# daemon_main — thin orchestrator over _daemon_setup + tick loop.
daemon_main() {
    _daemon_setup || return 1

    # v4.19.3 (PD-04): ALL traps in daemon_main scope instead of _daemon_setup scope.
    # With `emulate -L zsh` (LOCAL_TRAPS active) traps inside a function are
    # function-local. daemon_main runs the full daemon lifetime →
    # trap fire = shell-exit cleanup, USR1/TERM/INT stay active.
    # EXIT cleanup order is significant:
    # watcher_stop (orphan prevention) → cache_save → release_lock → log.
    trap '
        (( _DAEMON_WATCHER_ACTIVE )) && _watcher_stop
        (( ${+functions[_authority_cache_save]} )) && _authority_cache_save
        _release_daemon_lock
        log_event DAEMON_STOP "$$"
    ' EXIT
    trap _daemon_signal_usr1 USR1
    trap _daemon_signal_term TERM INT

    local interval state prev_state=""
    local disabled_before
    while (( _DAEMON_RUNNING )); do
        _daemon_check_watcher_liveness
        interval=$(_daemon_resolve_interval)
        state=$(read_state)

        # State-change detection + notification (loop-local prev_state tracking)
        if [[ "$state" != "$prev_state" ]]; then
            log_event STATE_CHANGE "${prev_state:-init}→${state}"
            _daemon_state_notify "$state"
            prev_state="$state"
        fi

        # E-06 (v4.18.0): track the disabled counter BEFORE the action for drift detection.
        # The delta after the action shows whether drift was recovered (≥1 Adobe component newly blocked).
        disabled_before=$_DAEMON_DISABLED

        _daemon_run_action "$state"

        # E-06: update the adaptive counter based on delta + TICK_NOW.
        _daemon_track_drift_for_adaptive "$disabled_before"

        _DAEMON_TICKS=$(( _DAEMON_TICKS + 1 ))
        live_state_write

        _daemon_periodic_maintenance
        _daemon_interruptible_sleep "$interval"
    done
    # DAEMON_STOP via EXIT trap (set in daemon_main)
}


# === TUI (status box + live activity + menu loop) — extracted to lib/tui.zsh (v4.4.0) ===
[[ -f "$ATM_LIB_DIR/tui.zsh" ]] && source "$ATM_LIB_DIR/tui.zsh"


# === Sudo sweep + Touch-ID detection — extracted to lib/pam.zsh (v4.4.0) ===
[[ -f "$ATM_LIB_DIR/pam.zsh" ]] && source "$ATM_LIB_DIR/pam.zsh"

summary_main() {
    if [[ "${1-}" == "--json" ]]; then
        json_emit_summary
        return 0
    fi
    print "=== Last 20 events (today + yesterday) ==="
    # v4.12.0: read both .log (legacy CSV) and .ndjson (NDJSON) — both
    # can exist in parallel during the 90d retention.
    local -a evt_files
    evt_files=( "$ATM_LOGS_DIR"/adobe-toggle.*.events.log(.NOm)
                "$ATM_LOGS_DIR"/adobe-toggle.*.events.ndjson(.NOm) )
    if (( ${#evt_files[@]} > 0 )); then
        local newest=( "${evt_files[1,2]}" )
        /bin/cat "${newest[@]}" 2>/dev/null | /usr/bin/tail -20
    else
        print "(no events)"
    fi
    print
    print "=== Live State ==="
    live_state_read || print "(no live_state)"
    print
    print "=== Disabled Labels ==="
    disabled_list_read || print "(none)"
    print
    print "=== Discovered (first 50) ==="
    /usr/bin/head -50 "$ATM_DISCOVERED_FILE" 2>/dev/null || print "(none)"
}

# === status_main (v4.7.0) ===
# Single-line human-readable or structured via --json. No re-run of
# discovery — only reads the snapshot from the last daemon tick.
status_main() {
    if [[ "${1-}" == "--json" ]]; then
        json_emit_status
        return 0
    fi
    local state pid ticks heartbeat_ts heartbeat_age safety_interval
    state=$(read_state 2>/dev/null) || state="unknown"
    pid=$(_json_daemon_pid)
    ticks=$(live_state_get ticks 2>/dev/null || print -- "0")
    ticks="${ticks:-0}"
    heartbeat_ts=$(live_state_get heartbeat_ts 2>/dev/null)
    safety_interval=$(_json_safety_tick_interval)
    if [[ -n "$heartbeat_ts" && "$heartbeat_ts" == <-> ]]; then
        heartbeat_age=$(( EPOCHSECONDS - heartbeat_ts ))
    else
        heartbeat_age="null"
    fi
    _json_health "$pid" "$heartbeat_age" "$safety_interval"
    printf "version=%s state=%s pid=%s ticks=%s heartbeat_age=%ss healthy=%s reason=%s\n" \
        "$APP_VERSION" "$state" "$pid" "$ticks" "$heartbeat_age" "$_JSON_HEALTHY" "$_JSON_HEALTH_REASON"
}

# === discovery_main (v4.7.0) ===
# Dump the current discovered.list snapshot. Default human-readable
# (TSV cat), --json structured.
discovery_main() {
    if [[ "${1-}" == "--json" ]]; then
        json_emit_discovery
        return 0
    fi
    if [[ -f "$ATM_DISCOVERED_FILE" ]]; then
        /bin/cat -- "$ATM_DISCOVERED_FILE"
    else
        print "(none — discovered.list missing; the daemon may not be running yet)"
    fi
}

# === health_main (v4.11.0) ===
# Health subcommand for monitoring + the healthcheck LaunchAgent.
# Returns: 0 = healthy, 1 = unhealthy.
# Reuses json_emit_status's health logic; output is a 1-line summary.
health_main() {
    local pid heartbeat_ts heartbeat_age safety_interval
    pid=$(_json_daemon_pid)
    heartbeat_ts=$(live_state_get heartbeat_ts 2>/dev/null)
    safety_interval=$(_json_safety_tick_interval)
    if [[ -n "$heartbeat_ts" && "$heartbeat_ts" == <-> ]]; then
        heartbeat_age=$(( EPOCHSECONDS - heartbeat_ts ))
    else
        heartbeat_age="null"
    fi
    _json_health "$pid" "$heartbeat_age" "$safety_interval"
    if [[ "$_JSON_HEALTHY" == "true" ]]; then
        print "healthy: pid=$pid heartbeat_age=${heartbeat_age}s"
        return 0
    else
        print -u2 -- "unhealthy: $_JSON_HEALTH_REASON (pid=$pid heartbeat_age=${heartbeat_age}s threshold=$(( safety_interval * 2 ))s)"
        return 1
    fi
}

# === healthcheck_main (v4.11.0) ===
# Silent self-healing: calls the health logic internally. On unhealthy:
# launchctl kickstart -k on the daemon label. Invoked by the healthcheck
# LaunchAgent every 5 min (StartInterval=300).
#
# Logs every run as a HEALTHCHECK_OK / HEALTHCHECK_RESTART event.
healthcheck_main() {
    local pid heartbeat_ts heartbeat_age safety_interval
    pid=$(_json_daemon_pid)
    heartbeat_ts=$(live_state_get heartbeat_ts 2>/dev/null)
    safety_interval=$(_json_safety_tick_interval)
    if [[ -n "$heartbeat_ts" && "$heartbeat_ts" == <-> ]]; then
        heartbeat_age=$(( EPOCHSECONDS - heartbeat_ts ))
    else
        heartbeat_age="null"
    fi
    _json_health "$pid" "$heartbeat_age" "$safety_interval"
    if [[ "$_JSON_HEALTHY" == "true" ]]; then
        # E-05 (v4.17.0): structured fields statt String-flattening
        log_event_structured HEALTHCHECK_OK "pid=${pid}" "age_s=${heartbeat_age}"
        return 0
    fi
    # Unhealthy → kickstart -k on the daemon (immediate restart via launchd).
    log_event_structured HEALTHCHECK_RESTART "reason=${_JSON_HEALTH_REASON}" "pid=${pid}" "age_s=${heartbeat_age}"
    log_warn "healthcheck: daemon unhealthy ($_JSON_HEALTH_REASON), kickstarting"
    _launchctl kickstart -k "gui/${UID}/${APP_LABEL}" 2>/dev/null \
        || log_warn "healthcheck: launchctl kickstart failed"
    return 1
}

help_main() {
    local script="${ZSH_SCRIPT:-adobe-toggle}"
    /bin/cat <<EOF
$APP_NAME $APP_VERSION

Usage:
  $script [--tui]              TUI (default)
  $script --daemon             Headless daemon (invoked by the LaunchAgent)
  $script status [--json]      Current state + daemon health (single-line / JSON)
  $script health               Health probe (exit 0 healthy, 1 unhealthy)
  $script --healthcheck        Self-healing (invoked by the healthcheck LaunchAgent)
  $script discovery [--json]   Snapshot of the current discovered.list
  $script summary [--json]     Aggregated view (events + state + disabled)
  $script --summary            (Backward-compat alias for 'summary')
  $script config <key> [val]   Show / set configuration
                               (keys: tick-interval, safety-tick-interval,
                                notifications, auto-start-cc, auto-sudo-sweep,
                                adaptive-interval — opt-in, trades drift latency
                                for CPU; default off)
  $script --version
  $script --help
EOF
}
