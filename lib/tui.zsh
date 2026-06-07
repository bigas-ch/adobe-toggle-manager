#!/bin/zsh
# === lib/tui.zsh — Terminal UI: status box + live activity + menu loop ===
# Module responsibility: complete TUI layer — fixed 60×9 boxes with
# status (left, vertically centered) + live activity (right, with
# gradient border + heartbeat + counters + drift events).
#
# Dependencies: box (rendering primitives), state (read_state, write_state,
# live_state_*), config (config_get), discovery (block_action, allow_action,
# discovery_sweep, _recent_drift_events-equivalent), pam (sudo_sweep_action),
# notify, log.
#
# Global TUI status variable (transient, shown in the activity panel):
typeset -g _ATM_STATUS_MSG=""

# === TUI ===
_daemon_pid() {
    _launchctl print "gui/${UID}/${APP_LABEL}" 2>/dev/null \
        | /usr/bin/awk '/pid =/ {gsub(/[^0-9]/, "", $3); print $3; exit}'
}

_term_cols() {
    local cols
    cols=$(/usr/bin/tput cols 2>/dev/null) || cols=120
    [[ "$cols" == <-> ]] || cols=120
    print -- "$cols"
}

# QW-1: shared NDJSON events-file glob. Since v4.12.0 logging writes ONLY
# *.events.ndjson (the legacy *.events.log CSV no longer receives writes), so
# all status/drift consumers must read .ndjson. Returns newest-first.
# zsh glob qualifier (.NOm): regular files (.), no-error-on-no-match (N),
# order by mtime newest first (Om).
_events_files() {
    local -a files
    files=( "$ATM_LOGS_DIR"/adobe-toggle.*.events.ndjson(.NOm) )
    (( ${#files[@]} == 0 )) && return 0
    print -rl -- "${files[@]}"
}

# QW-1: extract a single string field from one NDJSON object line via pure
# zsh ${} (no jq/python dependency — mirrors json.zsh's zero-dep philosophy).
# Matches "<field>":"<value>" and returns the unescaped-enough value (logged
# values are plain labels/timestamps without embedded quotes). Returns empty
# when the field is absent.
_ndjson_field() {
    local line="$1" field="$2" rest val
    # Cut everything up to and including the field key + opening quote.
    rest="${line#*\"${field}\":\"}"
    [[ "$rest" == "$line" ]] && { print -r -- ""; return 0; }
    # Value ends at the next unescaped double quote.
    val="${rest%%\"*}"
    print -r -- "$val"
}

# Format relative time (seconds) as a compact description
_fmt_relative() {
    local secs="$1"
    [[ "$secs" == <-> ]] || { print -- "—"; return; }
    if (( secs < 0 )); then
        print -- "in the future?"
    elif (( secs < 60 )); then
        print -- "${secs} s ago"
    elif (( secs < 3600 )); then
        print -- "$(( secs / 60 )) min ago"
    elif (( secs < 86400 )); then
        print -- "$(( secs / 3600 )) h ago"
    else
        print -- "$(( secs / 86400 )) days ago"
    fi
}

# Collects the last N DISABLED|KILLED events from the daily events logs.
# QW-1: reads *.events.ndjson (the live format since v4.12.0) and emits a
# stable "ts,event,details" CSV-like line per matching event, so the existing
# comma-split parsers in _activity_lines_for_box / _render_drift_section keep
# working unchanged downstream.
_recent_drift_events() {
    local n="${1:-5}"
    local -a files
    files=( "${(@f)$(_events_files)}" )
    (( ${#files[@]} == 0 )) && return 0
    # Take up to the 3 most recent files (already newest-first from _events_files).
    local newest=( "${files[1,3]}" )
    local line event
    /bin/cat "${newest[@]}" 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        event=$(_ndjson_field "$line" event)
        [[ "$event" == "DISABLED" || "$event" == "KILLED" ]] || continue
        print -r -- "$(_ndjson_field "$line" ts),${event},$(_ndjson_field "$line" details)"
    done | /usr/bin/tail -"$n"
}

# Builds the status box content lines (without borders)
_status_lines_for_box() {
    local inner_width="$1"
    local state daemon_pid disc_n disabled_n last_event state_emoji
    init_state
    state=$(read_state)
    daemon_pid=$(_daemon_pid)
    disc_n=0; disabled_n=0
    [[ -f "$ATM_DISCOVERED_FILE" ]] && disc_n=$(/usr/bin/wc -l < "$ATM_DISCOVERED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    [[ -f "$ATM_DISABLED_FILE" ]]   && disabled_n=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    # Last event from the daily events logs.
    # QW-1: read *.events.ndjson and render the last entry as "time event details"
    # (previously read the dead *.events.log CSV → always "—" since v4.12.0).
    local -a evt_files
    evt_files=( "${(@f)$(_events_files)}" )
    if (( ${#evt_files[@]} > 0 )); then
        local raw_last le_ts le_event le_details le_time
        raw_last=$(/usr/bin/tail -1 "${evt_files[1]}" 2>/dev/null)
        if [[ -n "$raw_last" ]]; then
            le_ts=$(_ndjson_field "$raw_last" ts)
            le_event=$(_ndjson_field "$raw_last" event)
            le_details=$(_ndjson_field "$raw_last" details)
            le_time="${le_ts:11:8}"
            [[ -z "$le_time" ]] && le_time="--:--:--"
            last_event="${le_time} ${le_event} ${le_details}"
        fi
    fi
    [[ -z "$last_event" ]] && last_event="—"

    state_emoji="🔴"
    [[ "$state" == "lean" ]] && state_emoji="🟡"
    [[ "$state" == "allow" ]] && state_emoji="🟢"

    print -r -- "State:       $state_emoji $state"
    print -r -- "Daemon-PID:  ${daemon_pid:-—}"
    print -r -- "Discovered:  ${disc_n:-0} (plists + processes)"
    print -r -- "Disabled:    ${disabled_n:-0} labels"
    print -r -- "Last Event:  $last_event"
    # Lean breakdown (only in lean): how many bloat components are off. Cheap —
    # in lean, disabled.list holds exactly the lean-blocked (bloat) set; the rest
    # (essentials) keep running. Conditional so the block/allow box is unchanged
    # and the 7-line box cap is respected (max 5 fixed + this + the pending line).
    [[ "$state" == "lean" ]] && print -r -- "Lean:        ${disabled_n:-0} bloat off · essentials kept"
    # v4.19.0 PHANTOM-FIX (C): show the pending hint only when there is real work —
    # the 6th line then appears centered in the 7-line status box.
    local pending_n
    pending_n=$(live_state_get pending_system 2>/dev/null) || pending_n=0
    if [[ -n "$pending_n" ]] && (( pending_n > 0 )); then
        print -r -- "⚠️  Pending:    ${pending_n} system items — press [e]"
    fi
}

# Builds the live activity content lines (without borders)
_activity_lines_for_box() {
    local inner_width="$1"
    local hb_ts now diff hb_str hb_rel
    hb_ts=$(live_state_get heartbeat_ts 2>/dev/null)
    now=$EPOCHSECONDS
    if [[ -n "$hb_ts" && "$hb_ts" == <-> ]]; then
        hb_str=$(/bin/date -r "$hb_ts" +"%H:%M:%S" 2>/dev/null || echo "—")
        diff=$(( now - hb_ts ))
        hb_rel=$(_fmt_relative "$diff")
    else
        hb_str="—"
        hb_rel="no daemon active"
    fi

    local ticks disabled killed
    ticks=$(live_state_get ticks 2>/dev/null || print 0)
    disabled=$(live_state_get disabled 2>/dev/null || print 0)
    killed=$(live_state_get killed 2>/dev/null || print 0)
    # v4.1.1 TUI-2 fix: show "current/total" — current = since-daemon-start,
    # total = entries currently in disabled.list. Disambiguates "DISABLED: 0"
    # which previously suggested "nothing disabled" when in fact 9+ items were.
    local disabled_total=0
    [[ -f "$ATM_DISABLED_FILE" ]] && disabled_total=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')

    # Layout exactly 7 inner lines, compact:
    # 1) heartbeat
    # 2) (empty)
    # 3) counter line (combined)
    # 4) (empty)
    # 5) recent drift events:
    # 6) drift event 1  (or "(none ...)")
    # 7) drift event 2  (optional, empty when not present)
    # Layout exactly 7 inner lines:
    # 1) heartbeat
    # 2) (empty)
    # 3) counter line
    # 4) (empty)
    # 5) recent drift events:
    # 6) drift event 1 or "(none ...)"
    # 7) drift event 2 (optional, empty if < 2 events)
    #
    # Status messages are NOT inserted here — they are written via
    # _render_with_blink directly into terminal rows 6/7/8
    # (targeted update via cursor positioning).
    print -r -- "● Heartbeat:  ${hb_str} (${hb_rel})"
    print -r -- ""
    print -r -- "DISABLED: ${disabled}/${disabled_total}   KILLED: ${killed}   TICKS: ${ticks}"
    print -r -- ""
    print -r -- "Recent drift events:"

    local line ts_iso action details time_part details_short
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ts_iso="${line%%,*}"
        local rest1="${line#*,}"
        action="${rest1%%,*}"
        details="${rest1#*,}"
        time_part="${ts_iso:11:8}"
        [[ -z "$time_part" ]] && time_part="--:--:--"
        details_short="$details"
        print -r -- "  ${time_part}  ${action}  ${details_short}"
        count=$(( count + 1 ))
        (( count >= 2 )) && break
    done < <(_recent_drift_events 2)
    if (( count == 0 )); then
        print -r -- "  (no drift events since daemon start)"
        print -r -- ""
    elif (( count == 1 )); then
        print -r -- ""
    fi
}

# Writes a single line into the right box panel via cursor positioning.
# row: 1-indexed terminal line (box top = 1; right box inner lines 1–7 correspond to terminal rows 2–8)
# content: raw text (truncated/padded to box inner width)
_render_right_box_line() {
    local row="$1" content="$2"
    # box inner width = 58 chars; with 1 char pad left + right → content_width = 56
    local content_width=56
    local padded
    padded=$(_pad_truncate "$content" "$content_width")
    # Position: row, column 62 (= 60 (left box) + 1 gap + 1 for border start)
    # Output: "│ <content padded to 56 cells> │" = 60 chars total
    printf '\033[%d;62H│ %s │' "$row" "$padded"
}

# Statically re-renders the drift events section (terminal rows 6, 7, 8 of the right box).
# Called after the blink ends to bring the default content back into view.
_render_heartbeat_line() {
    local hb_ts now diff hb_str hb_rel
    hb_ts=$(live_state_get heartbeat_ts 2>/dev/null)
    now=$EPOCHSECONDS
    if [[ -n "$hb_ts" && "$hb_ts" == <-> ]]; then
        hb_str=$(/bin/date -r "$hb_ts" +"%H:%M:%S" 2>/dev/null || echo "—")
        diff=$(( now - hb_ts ))
        hb_rel=$(_fmt_relative "$diff")
    else
        hb_str="—"
        hb_rel="no daemon active"
    fi
    # Heartbeat is inner row 1 of the right box → terminal row 2
    _render_right_box_line 2 "● Heartbeat:  ${hb_str} (${hb_rel})"
    # v4.1.1 TUI-1 fix: also refresh the counter line (Inner-Row 3 = Terminal-Row 4)
    # so DISABLED/KILLED/TICKS update live without requiring a full re-render.
    _render_counter_line
}

# v4.1.1 TUI-1 fix: refresh the DISABLED/KILLED/TICKS counter line in-place.
# Reads live_state for current counters + disabled.list for total disabled count.
_render_counter_line() {
    local ticks disabled killed disabled_total
    ticks=$(live_state_get ticks 2>/dev/null || print 0)
    disabled=$(live_state_get disabled 2>/dev/null || print 0)
    killed=$(live_state_get killed 2>/dev/null || print 0)
    disabled_total=0
    [[ -f "$ATM_DISABLED_FILE" ]] && disabled_total=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    _render_right_box_line 4 "DISABLED: ${disabled}/${disabled_total}   KILLED: ${killed}   TICKS: ${ticks}"
}

_render_drift_section() {
    local -a evs
    evs=( "${(@f)$(_recent_drift_events 2)}" )
    local n=${#evs[@]}
    _render_right_box_line 6 "Recent drift events:"
    if (( n == 0 )); then
        _render_right_box_line 7 "  (no drift events since daemon start)"
        _render_right_box_line 8 ""
        return
    fi
    local i target_row ev ts_iso rest1 action details time_part
    for (( i=1; i<=2; i++ )); do
        target_row=$(( i + 6 ))   # → 7, 8
        ev="${evs[i]:-}"
        if [[ -n "$ev" ]]; then
            ts_iso="${ev%%,*}"
            rest1="${ev#*,}"
            action="${rest1%%,*}"
            details="${rest1#*,}"
            time_part="${ts_iso:11:8}"
            _render_right_box_line "$target_row" "  ${time_part}  ${action}  ${details}"
        else
            _render_right_box_line "$target_row" ""
        fi
    done
}

# Blinks ONLY the status line (terminal row 6 of the right box) — the rest of
# the terminal content stays put. 10 seconds, 2 Hz (250 ms toggle, 40 frames).
# Drift event lines 7+8 are cleared during the blink; after 10 s the
# drift events block is brought back via _render_drift_section.
_render_with_blink() {
    local msg="$1"
    # Only save the cursor position — the cursor is already hidden via tui_main;
    # we do NOT make it visible again at the end, so it stays gone for the whole
    # TUI lifetime. _tui_cleanup shows it on exit.
    printf '\033[s'

    # Clear the drift events area (lines 7+8) so the status stands alone
    _render_right_box_line 7 ""
    _render_right_box_line 8 ""

    # Blink loop: 40 frames × 250 ms — alternates line 6 between msg and empty
    # Heartbeat update every 4 frames (= 1 s) for a live display during the blink
    # Gradient border tick per frame (4 Hz)
    local i cur_state
    for (( i=0; i<40; i++ )); do
        if (( i % 2 == 0 )); then
            _render_right_box_line 6 "$msg"
        else
            _render_right_box_line 6 ""
        fi
        cur_state=$(read_state)
        _gradient_tick "$cur_state"
        (( i % 4 == 0 )) && _render_heartbeat_line
        /bin/sleep 0.25
    done

    # After the blink: bring the drift events block back (static)
    _render_drift_section

    # Restore the cursor to the saved position — do NOT make it visible again
    # (tui_main hid it for the whole TUI; _tui_cleanup shows it on
    # exit). If we set '\033[?25h' here the cursor would come back
    # and flicker through the TUI on every animation frame.
    printf '\033[u'
}

tui_render_status() {
    # FIXED box dimensions — no more terminal-width logic (user instruction 2026-05-02)
    # BOX_WIDTH = 60 chars total (incl. borders)
    # BOX_INNER_HEIGHT = 7 inner lines (between top + bottom border)
    # → total box height = 9 lines (1 top + 7 inner + 1 bottom)
    local box_width=60
    local box_inner_width=$(( box_width - 2 ))   # = 58
    local box_inner_height=7

    # Build the content (5 status lines + up to 7 activity lines)
    local -a status_content activity_content
    status_content=( "${(@f)$(_status_lines_for_box "$box_inner_width")}" )
    activity_content=( "${(@f)$(_activity_lines_for_box "$box_inner_width")}" )

    # Vertical centering: distribute padding so the content reaches box_inner_height
    # With 5 content + 7 inner → 2 padding → 1 top + 1 bottom
    local -a status_centered activity_centered
    _vertical_center status_content "$box_inner_height" status_centered
    _vertical_center activity_content "$box_inner_height" activity_centered

    # Box lines: top + 7 inner + bottom (= 9 total)
    local -a left_box right_box
    left_box=( "$(_box_top "Adobe Toggle v$APP_VERSION" "$box_inner_width")" )
    local line
    for line in "${status_centered[@]}"; do
        left_box+=( "$(_box_line "$line" "$box_inner_width")" )
    done
    left_box+=( "$(_box_bottom "$box_inner_width")" )

    right_box=( "$(_box_top "Live Activity" "$box_inner_width")" )
    for line in "${activity_centered[@]}"; do
        right_box+=( "$(_box_line "$line" "$box_inner_width")" )
    done
    right_box+=( "$(_box_bottom "$box_inner_width")" )

    # Render side by side (1 char gap)
    local i n=${#left_box[@]}
    for (( i=1; i<=n; i++ )); do
        printf '%s %s\n' "${left_box[i]}" "${right_box[i]}"
    done
}

_tui_signal_daemon() {
    local pid
    pid=$(_daemon_pid)
    [[ -n "$pid" && "$pid" != "—" ]] && kill -USR1 "$pid" 2>/dev/null && return 0
    return 1
}

_tui_render_menu_hint() {
    /bin/cat <<EOF

  [a] 🟢 Allow       → release Adobe components
  [b] 🔴 Block       → stop Adobe completely
  [l] 🟡 Lean        → stop only Adobe bloat, keep apps usable
  [d] Force discovery now
  [s] Statistics / logs
  [u] 🔧 Sudo-Sweep  → disable system LaunchDaemons (sudo)
  [e] 🟢 Sudo-Unsweep → enable system LaunchDaemons (sudo, after Allow)
  [w] 🟢 Whitelist   → fzf picker for per-component user_allowed
  [q] Exit
EOF
}

# One-line stats summary for the status display (shown in the right panel)
_stats_summary_line() {
    # QW-1: count from *.events.ndjson (the live format since v4.12.0); the
    # legacy *.events.log CSV no longer receives writes → always counted 0.
    local -a evt_files
    evt_files=( "${(@f)$(_events_files)}" )
    local today_events=0
    if (( ${#evt_files[@]} > 0 )); then
        today_events=$(/usr/bin/wc -l < "${evt_files[1]}" 2>/dev/null | /usr/bin/tr -d ' ')
    fi
    local disabled_n=0 disc_n=0
    [[ -f "$ATM_DISABLED_FILE" ]]   && disabled_n=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    [[ -f "$ATM_DISCOVERED_FILE" ]] && disc_n=$(/usr/bin/wc -l < "$ATM_DISCOVERED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    print -r -- "Stats: ${today_events} evt today, ${disabled_n} dis, ${disc_n} found"
}

# === PD-02 (v4.16.0): tui_menu_loop refactor ===
# Before: 120 LOC monolithic with an inline case switch over 7 actions.
# Now: the loop is a thin dispatcher, each action its own _tui_action_<key> function.
# Benefits: sub-functions testable individually, adding new keys = 1 new function.

# QW-6 (UX): surface a PERSISTENT Touch-ID hint when an auto-chain would fire
# but Touch-ID-for-sudo is disabled. Without this the chained sudo_sweep_action
# only flashes a "not enabled" snippet that the immediate re-render wipes → a
# first-time user presses [b] and the system-scope Adobe daemons keep running
# silently. We record pending_system (so the status-box warning line — the same
# one [e]/[u] use — persists across renders) and render an explicit blink hint.
# $1 = pending count, $2 = action key to point at ("u" for sweep, "e" for unsweep).
_tui_surface_touchid_hint() {
    local count="$1" key="$2"
    [[ "$count" == <-> ]] || count=0
    # Persistent: the status box reads live_state pending_system on every render.
    live_state_set pending_system "$count"
    _render_with_blink "⚠️  Touch-ID for sudo not enabled — ${count} system items still active. Enable it, then press [${key}]."
}

# _tui_action_a — set state to 'allow' + trigger the daemon.
_tui_action_a() {
    local sig_msg
    write_state allow
    if _tui_signal_daemon; then
        sig_msg="🟢 State 'allow' set — daemon triggered."
    else
        sig_msg="🟢 State 'allow' set (daemon not active)."
    fi
    # QW-3 (UX): when an auto-unsweep will follow, run the elevation FIRST so the
    # Touch-ID prompt appears immediately on keypress. The leading ~10 s blink is
    # skipped in that case — _tui_action_e renders its own result blink afterward.
    # v4.20.0: auto-chain the system-scope sudo-unsweep when enabled and there
    # are disabled system entries to re-enable; mirrors the block path.
    if _auto_sudo_sweep_enabled && _pending_system_unsweep; then
        # QW-6: chaining only makes sense with Touch-ID for sudo. Otherwise the
        # chained action would flash + abort, leaving system daemons disabled and
        # the user misinformed → surface a persistent hint instead.
        if _touchid_for_sudo_enabled; then
            _tui_action_e
        else
            _tui_surface_touchid_hint "$(_pending_system_unsweep_count)" e
        fi
    else
        _render_with_blink "$sig_msg"
    fi
}

# _tui_action_b — set state to 'block' + trigger the daemon.
_tui_action_b() {
    local sig_msg
    write_state block
    if _tui_signal_daemon; then
        sig_msg="🔴 State 'block' set — daemon triggered."
    else
        sig_msg="🔴 State 'block' set (daemon not active)."
    fi
    # QW-3 (UX): when an auto-sweep will follow, run the elevation FIRST so the
    # Touch-ID prompt appears immediately on keypress instead of ~10 s later (the
    # blocking _render_with_blink loop). The leading blink is skipped in that case
    # — _tui_action_u renders its own result blink afterward.
    # v4.20.0: auto-chain the system-scope sudo-sweep when enabled and there is
    # pending work, so the separate [u] step is not needed. The pre-check is
    # non-sudo, so no Touch-ID prompt appears when nothing needs blocking.
    if _auto_sudo_sweep_enabled && _pending_system_sweep; then
        # QW-6: the auto-chain needs Touch-ID for sudo. Without it, sudo_sweep_action
        # only flashes a "not enabled" snippet that the immediate re-render wipes →
        # the system-scope Adobe daemons would silently keep running. Surface a
        # persistent visible hint (status-box warning + blink) instead of aborting.
        if _touchid_for_sudo_enabled; then
            _tui_action_u
        else
            _tui_surface_touchid_hint "$(_pending_system_sweep_count)" u
        fi
    else
        _render_with_blink "$sig_msg"
    fi
}

# _tui_action_l — set state to 'lean' (block only curated bloat) + trigger the
# daemon. No auto-sudo-sweep chain: lean must NOT sweep all system LaunchDaemons
# (that is full-block behavior); system-scope bloat is handled via the explicit
# [u] sweep when desired.
_tui_action_l() {
    local sig_msg
    write_state lean
    if _tui_signal_daemon; then
        sig_msg="🟡 State 'lean' set — daemon triggered."
    else
        sig_msg="🟡 State 'lean' set (daemon not active)."
    fi
    # No auto-sudo-sweep chain (lean must NOT sweep all system LaunchDaemons —
    # that is full-block behaviour). But if a prior Block left ESSENTIAL
    # (non-bloat) system daemons disabled, the user-mode daemon cannot re-enable
    # them without sudo → surface a persistent hint so the user can recover via
    # [e]. Bloat system daemons correctly stay off and are NOT counted, so the
    # hint only fires for genuine essentials (avoids inviting a bloat re-enable).
    local stuck
    stuck=$(_lean_pending_essential_system_count)
    if [[ "$stuck" == <1-> ]]; then
        live_state_set pending_system "$stuck"
        _render_with_blink "${sig_msg} ⚠️  ${stuck} essential system item(s) still disabled from a prior Block — press [e] to re-enable (sudo)."
    else
        _render_with_blink "$sig_msg"
    fi
}

# _tui_action_d — manual discovery + show the component count.
_tui_action_d() {
    discovery_sweep
    local n
    n=$(/usr/bin/wc -l < "$ATM_DISCOVERED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    _render_with_blink "Discovery: ${n:-0} components found."
}

# _tui_action_s — show the stats summary.
_tui_action_s() {
    _render_with_blink "$(_stats_summary_line)"
}

# _tui_action_u — sudo-sweep (interactive with askpass).
# The TTY must stay intact for the sudo prompt → reset the screen before the action.
_tui_action_u() {
    local before_n=0 after_n=0 added=0
    [[ -f "$ATM_DISABLED_FILE" ]] && before_n=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    /usr/bin/clear 2>/dev/null || printf '\033[2J\033[H'
    sudo_sweep_action
    [[ -f "$ATM_DISABLED_FILE" ]] && after_n=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    added=$(( after_n - before_n ))
    # TUI restore — _render_with_blink assumes the TUI starts at row 1
    printf '\033[H\033[J'
    tui_render_status
    _tui_render_menu_hint
    if (( added > 0 )); then
        _render_with_blink "🔧 Sudo-Sweep: ${added} system daemons disabled."
    else
        _render_with_blink "🔧 Sudo-Sweep: no change."
    fi
}

# _tui_action_e — sudo-unsweep: enable system-scope Adobe LaunchDaemons
# (the Allow counterpart to _tui_action_u). Mandatory after the state changes to
# 'allow' so Genuine/ARMDC/installer.v2 run again — otherwise Adobe CC breaks with
# license and update errors (see lib/pam.zsh sudo_unsweep_action).
# v4.19.0: the TTY must stay intact for the sudo prompt → reset the screen.
_tui_action_e() {
    local before_n=0 after_n=0 enabled=0
    [[ -f "$ATM_DISABLED_FILE" ]] && before_n=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    /usr/bin/clear 2>/dev/null || printf '\033[2J\033[H'
    sudo_unsweep_action
    [[ -f "$ATM_DISABLED_FILE" ]] && after_n=$(/usr/bin/wc -l < "$ATM_DISABLED_FILE" 2>/dev/null | /usr/bin/tr -d ' ')
    enabled=$(( before_n - after_n ))
    printf '\033[H\033[J'
    tui_render_status
    _tui_render_menu_hint
    if (( enabled > 0 )); then
        _render_with_blink "🟢 Sudo-Unsweep: ${enabled} system daemons enabled."
    else
        _render_with_blink "🟢 Sudo-Unsweep: no change."
    fi
}

# _tui_action_w — whitelist manager (interactive fzf picker).
# Like the sudo-sweep: clear the screen, then re-render the TUI afterward.
_tui_action_w() {
    /usr/bin/clear 2>/dev/null || printf '\033[2J\033[H'
    whitelist_main
    printf "\nPress ENTER to return to the TUI..."
    read -r _
    printf '\033[H\033[J'
    tui_render_status
    _tui_render_menu_hint
    _render_with_blink "🟢 Whitelist updated (see disabled.list)."
}

# _tui_read_key_with_animation — waits for a keypress, animates while idle.
# stdout: the chosen key. The read timeout drives the animation at 4 Hz.
# IMPORTANT: uses the outer var `choice` (the typical zsh read-into-var pattern).
_tui_read_key_with_animation() {
    local cur_state tick_count=0
    while true; do
        # -s = silent (no echo, otherwise it destroys the TUI)
        # -k 1 = single key (no Enter needed)
        # -t 0.25 = 250ms timeout per animation frame (4 Hz)
        if read -s -k 1 -t 0.25 choice; then
            return 0
        fi
        # Timeout → animation tick
        cur_state=$(read_state)
        printf '\033[s'   # cursor save
        _gradient_tick "$cur_state"
        if (( tick_count % 4 == 0 )); then
            _render_heartbeat_line
        fi
        printf '\033[u'   # cursor restore
        tick_count=$(( tick_count + 1 ))
    done
}

# _tui_full_render — clear + status + menu-hint + initial-border.
_tui_full_render() {
    local first_iter="$1"
    if (( first_iter )); then
        /usr/bin/clear 2>/dev/null || printf '\033[2J\033[H'
    else
        printf '\033[H\033[J'   # cursor home + erase-from-cursor-down
    fi
    tui_render_status
    _tui_render_menu_hint
    printf "\n  > "
    _render_right_border_full
}

# tui_menu_loop — thin dispatcher: render → read → action.
# Action lookup via the _tui_action_<key> function naming convention.
# 'q' or empty input → exit. Unknown keys → blink warning.
tui_menu_loop() {
    # Declare ALL locals once — zsh quirk: a duplicate `local var` prints
    # `var=<value>` to the terminal and overwrites the border animation.
    local choice first_iter=1
    while true; do
        _tui_full_render "$first_iter"
        first_iter=0

        choice=""
        _tui_read_key_with_animation

        case "$choice" in
            q|"") return 0 ;;
        esac

        # Action dispatch via function lookup (PD-02 pattern).
        # Only a-z allowed as a key ID (safety: no $(...) etc. in $choice).
        if [[ "$choice" =~ ^[a-z]$ ]] && (( ${+functions[_tui_action_${choice}]} )); then
            "_tui_action_${choice}"
        else
            _render_with_blink "Unknown input: '$choice'"
        fi
    done
}

_tui_cleanup() {
    # Show the cursor again + leave the alternate screen buffer.
    # Also called via trap on SIGINT/SIGTERM → no polluted
    # terminal content after a crash or Ctrl-C.
    printf '\033[?25h\033[?1049l'
}

tui_main() {
    init_state
    # Alternate screen buffer (like vim/htop) + hide the cursor:
    # \033[?1049h — enter alt screen + save current screen content
    # \033[?25l   — hide the cursor (otherwise it flickers on every
    #                ANSI cursor move during the border animation
    #                and even overwrites title characters).
    # Cleanup in _tui_cleanup undoes both.
    printf '\033[?1049h\033[?25l'
    trap _tui_cleanup EXIT INT TERM
    tui_menu_loop
    _tui_cleanup
    trap - EXIT INT TERM
}
