#!/bin/zsh
# === Adobe Toggle v4 — Uninstaller ===
# Version: 1.1.0 (MINOR — phase_release_adobe now performs the sudo unsweep
# itself for leftover system-scope entries in disabled.list (previously: only
# a WARN hint to the user with a WRONG TUI reference to [u] instead of [e]). The
# uninstall flow is interactive anyway (confirm phase), so the Touch-ID prompt
# fits in seamlessly. Prevents Adobe CC from being left in a half-blocked
# system state after uninstall — same bug pattern as the v4.19.0 PHANTOM-FIX
# in allow_action, but in the uninstall path.)
# Version: 1.0.0
# Forward-only removal in 9 phases (no rollback — deletion is irreversible):
#   confirm → release_adobe → backup_logs → bootout → kill_processes
#           → plists → appsupport → src_symlink → summary
#
# The source repo under ${0:A:h} is left UNTOUCHED. Only runtime artifacts
# are removed (~/Library/Application Support/AdobeToggleManager/,
# 2 LaunchAgents, daemon job + healthcheck job, source-side logs symlink).
#
# Options (env vars — analogous to install.sh):
#   ATM_BASE=/custom/path                  alternative runtime location
#   ATM_UNINSTALL_FORCE=1                  no confirms (no-prompt)
#   ATM_UNINSTALL_DRY_RUN=1                only show, change nothing
#   ATM_UNINSTALL_BACKUP_LOGS=yes|no|<path>
#       yes   → default path ($TMPDIR/AdobeToggleManager_uninstall_backup/logs_<ts>)
#       no    → no backup, logs are deleted along with everything else
#       <path>→ explicit backup path
#       (empty)→ ask interactively
#   ATM_UNINSTALL_SKIP_RELEASE=1           do NOT release Adobe beforehand
#                                          (dangerous — disabled.list stays active,
#                                          Adobe components remain blocked!)

set -u
emulate -L zsh
setopt PIPE_FAIL

# Hardened PATH (system binaries only)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 0077

# === Paths ===
typeset -gr SCRIPT_DIR="${0:A:h}"
typeset -g  APP_SUPPORT="${ATM_BASE:-$HOME/Library/Application Support/AdobeToggleManager}"
typeset -g  LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
typeset -g  PLIST_PATH="$LAUNCH_AGENTS/com.user.adobe-toggle.daemon.plist"
typeset -g  HEALTHCHECK_PLIST_PATH="$LAUNCH_AGENTS/com.user.adobe-toggle.healthcheck.plist"
typeset -gr LABEL="com.user.adobe-toggle.daemon"
typeset -gr HEALTHCHECK_LABEL="com.user.adobe-toggle.healthcheck"
typeset -g  CORE_DST="$APP_SUPPORT/adobe-toggle"
typeset -g  STATE_FILE="$APP_SUPPORT/state"
typeset -g  DISABLED_LIST="$APP_SUPPORT/disabled.list"
typeset -g  LOGS_DIR="$APP_SUPPORT/logs"
typeset -g  SRC_SYMLINK="$SCRIPT_DIR/logs"

# === Modes ===
typeset -gi DRY_RUN=${ATM_UNINSTALL_DRY_RUN:-0}
typeset -gi FORCE=${ATM_UNINSTALL_FORCE:-0}
typeset -gi SKIP_RELEASE=${ATM_UNINSTALL_SKIP_RELEASE:-0}
typeset -g  BACKUP_TARGET=""

# === Helpers ============================================================

# do_run — wrapper for mutating commands; respects DRY_RUN.
# Quotes args correctly for the [DRY] display.
do_run() {
    if (( DRY_RUN )); then
        print "  [DRY] $*"
        return 0
    fi
    "$@"
}

# write_file — DRY-aware redirect helper (single-line write).
write_file() {
    local content="$1" target="$2"
    if (( DRY_RUN )); then
        print "  [DRY] print -- '$content' > '$target'"
        return 0
    fi
    print -- "$content" > "$target"
}

# prompt_yes_no — Y/N with default. With FORCE: default without prompt.
prompt_yes_no() {
    local msg="$1"
    local default="${2:-n}"
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    if (( FORCE )); then
        print "$msg $hint  → $default (FORCE)"
        [[ "$default" == "y" ]]
        return $?
    fi
    local answer
    print -n -- "$msg $hint "
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" == [yYjJ]* ]]
}

# === Phase: confirm ====================================================
phase_confirm() {
    print
    print "The following will be REMOVED:"
    print "  • LaunchAgent plist:  $PLIST_PATH"
    print "  • LaunchAgent plist:  $HEALTHCHECK_PLIST_PATH"
    print "  • LaunchAgent job:    gui/${UID}/${LABEL}"
    print "  • LaunchAgent job:    gui/${UID}/${HEALTHCHECK_LABEL}"
    print "  • Runtime dir:        $APP_SUPPORT"
    print "                        (entire dir, incl. lib/, state, *.list, swift, logs)"
    print "  • Source symlink:     $SRC_SYMLINK (if it is a symlink)"
    print
    print "The source repo under $SCRIPT_DIR stays unchanged."
    print "Adobe components are released beforehand (state=allow + SIGUSR1)."
    (( SKIP_RELEASE )) && print "  ⚠ ATM_UNINSTALL_SKIP_RELEASE=1 — release is SKIPPED."
    print
    if (( FORCE )); then
        print "FORCE mode: confirm skipped."
        return 0
    fi
    local answer
    print -n -- "Really uninstall? Type 'YES' to confirm: "
    read -r answer
    if [[ "$answer" != "YES" ]]; then
        print "Aborted."
        return 1
    fi
}

# === Phase: release_adobe ==============================================
# Before the bootout: state=allow + SIGUSR1 → daemon processes disabled.list
# and re-enables gui/user-scope launchd labels + pluginkit extensions.
# System-scope entries need sudo — they stay in disabled.list, the daemon
# logs WARN_NEEDS_SUDO. We warn the user and show the recovery command.
phase_release_adobe() {
    if (( SKIP_RELEASE )); then
        print "  skipped (ATM_UNINSTALL_SKIP_RELEASE=1)"
        print "  ⚠ Adobe components remain blocked — release manually via TUI [a] or set $CORE_DST allow."
        return 0
    fi
    if [[ ! -f "$STATE_FILE" || ! -f "$CORE_DST" ]]; then
        print "  state/core not found — tool may already be half-uninstalled, skipping"
        return 0
    fi

    local current
    current=$(/bin/cat "$STATE_FILE" 2>/dev/null || print "unknown")
    print "  current state: $current"

    if [[ "$current" != "allow" ]]; then
        write_file "allow" "$STATE_FILE" || return 1
        print "  state → allow"
    fi

    # Daemon PID via launchctl (reliable as long as the job is loaded)
    local pid=""
    pid=$(/bin/launchctl print "gui/${UID}/${LABEL}" 2>/dev/null \
          | /usr/bin/awk '/pid =/ {gsub(/[^0-9]/, "", $3); print $3; exit}')
    if [[ -z "$pid" || "$pid" == "0" ]]; then
        print "  daemon not running — disabled.list will not be processed on a manual re-install"
        return 0
    fi

    do_run /bin/kill -USR1 "$pid" 2>/dev/null || true
    print "  SIGUSR1 → daemon (pid $pid)"

    # In DRY_RUN, do not wait (daemon state unchanged)
    if (( DRY_RUN )); then
        print "  [DRY] no polling for disabled.list to empty"
        return 0
    fi

    # Polling: wait up to 15s for disabled.list to empty (except user_allowed entries)
    local i=0
    local -i remaining=999
    while (( i < 30 )); do
        if [[ ! -f "$DISABLED_LIST" ]]; then
            remaining=0; break
        fi
        # Schema: label\tscope\tdisabled_at\tstate. user_allowed may remain.
        remaining=$(/usr/bin/awk -F'\t' '$4 != "user_allowed" {c++} END {print c+0}' \
                    "$DISABLED_LIST" 2>/dev/null)
        (( remaining == 0 )) && break
        /bin/sleep 0.5
        (( i++ ))
    done

    if (( remaining == 0 )); then
        print "  ✓ disabled.list empty — all gui/user-scope components released"
        return 0
    fi

    # v1.1.0: inline sudo unsweep for system-scope entries (previously: only
    # a WARN hint). We read the system-scope labels from disabled.list,
    # offer the user a sudo unsweep, and run launchctl enable + bootstrap
    # per label with Touch-ID/password. user_allowed stays filtered out of
    # disabled.list (user intent: keep it blocked).
    local -a system_labels=()
    local label scope ts state
    while IFS=$'\t' read -r label scope ts state; do
        [[ -z "$label" ]] && continue
        [[ "$scope" != "system" ]] && continue
        [[ "$state" == "user_allowed" ]] && continue
        system_labels+=( "$label" )
    done < "$DISABLED_LIST"

    if (( ${#system_labels[@]} == 0 )); then
        print -u2 -- "  ⚠ $remaining non-system entries left — check disabled.list manually:"
        print -u2 -- "       cat '$DISABLED_LIST'"
        if ! prompt_yes_no "Continue anyway?" n; then
            return 1
        fi
        return 0
    fi

    print -u2 -- "  ⚠ ${#system_labels[@]} system-scope entries left — need sudo to re-enable:"
    local lbl
    for lbl in "${system_labels[@]}"; do
        print -u2 -- "      • $lbl"
    done
    print

    if (( DRY_RUN )); then
        print "  [DRY] sudo unsweep of the ${#system_labels[@]} system items skipped"
        return 0
    fi

    if ! prompt_yes_no "Run sudo unsweep? (Touch-ID/password prompt appears)" y; then
        print -u2 -- "  ⚠ Skipped — Adobe stays blocked for system-scope."
        print -u2 -- "      Recover later via TUI: [e] Sudo-Unsweep + [a] Allow"
        if ! prompt_yes_no "Continue with uninstall anyway?" n; then
            return 1
        fi
        return 0
    fi

    # sudo -v caches creds for 5 min — one auth for all enable+bootstrap calls.
    print "  → Touch-ID/password auth..."
    if ! /usr/bin/sudo -v; then
        print -u2 -- "  ❌ Sudo auth failed — Adobe stays blocked."
        if ! prompt_yes_no "Continue anyway?" n; then
            return 1
        fi
        return 0
    fi

    local fail=0 ok=0
    for lbl in "${system_labels[@]}"; do
        if /usr/bin/sudo /bin/launchctl enable "system/${lbl}" 2>/dev/null; then
            ok=$(( ok + 1 ))
            local plist="/Library/LaunchDaemons/${lbl}.plist"
            [[ -f "$plist" ]] && /usr/bin/sudo /bin/launchctl bootstrap system "$plist" 2>/dev/null || true
        else
            fail=$(( fail + 1 ))
            print -u2 -- "      ✗ enable failed: $lbl"
        fi
    done

    if (( fail == 0 )); then
        print "  ✓ ${ok} system LaunchDaemons re-enabled — Adobe fully released."
        # Clean successfully enabled system entries out of disabled.list,
        # so the daemon bootout that follows shortly sees no leftovers.
        local tmp="${DISABLED_LIST}.tmp.$$"
        : > "$tmp"
        while IFS=$'\t' read -r label scope ts state; do
            [[ -z "$label" ]] && continue
            if [[ "$scope" == "system" && "$state" != "user_allowed" ]]; then
                continue
            fi
            print -- "${label}\t${scope}\t${ts}\t${state}" >> "$tmp"
        done < "$DISABLED_LIST"
        /bin/mv -f "$tmp" "$DISABLED_LIST"
    else
        print -u2 -- "  ⚠ ${ok} ok, ${fail} failed — check manually:"
        print -u2 -- "       /bin/launchctl print-disabled system | grep -E 'adobe|Genuine|ARMDC'"
        if ! prompt_yes_no "Continue anyway?" n; then
            return 1
        fi
    fi
}

# === Phase: backup_logs =================================================
phase_backup_logs() {
    if [[ ! -d "$LOGS_DIR" ]]; then
        print "  no logs found — skipping"
        return 0
    fi

    local mode="${ATM_UNINSTALL_BACKUP_LOGS:-}"
    local default_target
    default_target="${TMPDIR:-/tmp/}AdobeToggleManager_uninstall_backup/logs_$(/bin/date +%Y%m%d_%H%M%S)"
    local target=""

    case "$mode" in
        no|NO|n|N)
            print "  no backup (ATM_UNINSTALL_BACKUP_LOGS=no)"
            return 0
            ;;
        yes|YES|y|Y|j|J|ja|JA)
            target="$default_target"
            ;;
        "")
            # interactive
            if (( FORCE )); then
                # FORCE without an explicit choice → default = backup to default path.
                # Safe default: better to back up than to delete unintentionally.
                target="$default_target"
            else
                local size
                size=$(/usr/bin/du -sh "$LOGS_DIR" 2>/dev/null | /usr/bin/awk '{print $1}')
                print "  Logs size: ${size:-unknown} ($LOGS_DIR)"
                if prompt_yes_no "Back up log files before deleting?" y; then
                    print -n -- "  Backup path [Enter = $default_target]: "
                    local input
                    read -r input
                    target="${input:-$default_target}"
                else
                    print "  no backup."
                    return 0
                fi
            fi
            ;;
        /*)
            target="$mode"
            ;;
        *)
            print -u2 -- "  ❌ ATM_UNINSTALL_BACKUP_LOGS must be yes|no|<absolute-path>, not '$mode'"
            return 1
            ;;
    esac

    do_run /bin/mkdir -p "${target:h}" || return 1
    do_run /bin/cp -R "$LOGS_DIR" "$target" || return 1
    BACKUP_TARGET="$target"
    print "  ✓ logs backed up → $target"
}

# === Phase: bootout =====================================================
phase_bootout() {
    local lbl
    for lbl in "$LABEL" "$HEALTHCHECK_LABEL"; do
        if /bin/launchctl print "gui/${UID}/${lbl}" >/dev/null 2>&1; then
            do_run /bin/launchctl bootout "gui/${UID}/${lbl}" 2>/dev/null || true
            print "  bootout: $lbl"
            # wait until fully booted out (max 5s)
            (( DRY_RUN )) && continue
            local i=0
            while (( i < 25 )) && /bin/launchctl print "gui/${UID}/${lbl}" >/dev/null 2>&1; do
                /bin/sleep 0.2
                (( i++ ))
            done
        else
            print "  $lbl was not loaded"
        fi
    done
}

# === Phase: kill_processes =============================================
# After bootout the daemon + watcher (child) should be gone. If orphans
# remain: search via the [a]dobe-toggle / [a]tm-watcher trick (does NOT match
# our own pgrep invocation, because the bracket pattern appears in the pgrep
# cmdline as '[a]dobe', but as 'adobe' in the running zsh process).
phase_kill_processes() {
    typeset -aU pids=()
    local p
    # [a]dobe-toggle = current name; [a]dobe_toggle_v4.sh = pre-1.0 name still
    # running on an in-place upgrade (transition safety); [a]tm-watcher = the FSEvents helper.
    for pat in "[a]dobe-toggle" "[a]dobe_toggle_v4.sh" "[a]tm-watcher.swift"; do
        local -a found
        found=( ${(f)"$(/usr/bin/pgrep -f "$pat" 2>/dev/null)"} )
        for p in "${found[@]}"; do
            [[ "$p" == <-> ]] && pids+=("$p")
        done
    done

    if (( ${#pids[@]} == 0 )); then
        print "  no leftover processes"
        return 0
    fi

    print "  leftover processes: ${pids[*]}"
    for p in "${pids[@]}"; do
        do_run /bin/kill -TERM "$p" 2>/dev/null || true
    done
    (( DRY_RUN )) && return 0

    /bin/sleep 1
    for p in "${pids[@]}"; do
        if /bin/kill -0 "$p" 2>/dev/null; then
            do_run /bin/kill -KILL "$p" 2>/dev/null || true
            print "  KILL: $p (TERM ignored)"
        fi
    done
}

# === Phase: plists ======================================================
phase_plists() {
    local f
    for f in "$PLIST_PATH" "$HEALTHCHECK_PLIST_PATH"; do
        if [[ -f "$f" ]]; then
            do_run /bin/rm -f "$f" || return 1
            print "  rm: $f"
        else
            print "  already missing: $f"
        fi
    done
}

# === Phase: appsupport ==================================================
phase_appsupport() {
    if [[ -d "$APP_SUPPORT" ]]; then
        do_run /bin/rm -rf "$APP_SUPPORT" || return 1
        print "  rm -rf: $APP_SUPPORT"
    else
        print "  already missing: $APP_SUPPORT"
    fi
}

# === Phase: src_symlink =================================================
phase_src_symlink() {
    if [[ -L "$SRC_SYMLINK" ]]; then
        do_run /bin/rm -f "$SRC_SYMLINK" || return 1
        print "  rm: $SRC_SYMLINK (symlink)"
    elif [[ -d "$SRC_SYMLINK" ]]; then
        print "  ⚠ $SRC_SYMLINK is a real directory (not expected) — NOT deleted"
        print "      Check manually: $SRC_SYMLINK"
    else
        print "  symlink does not exist — skipping"
    fi
}

# === Phase: summary =====================================================
phase_summary() {
    print
    if (( DRY_RUN )); then
        print "🟡 DRY-RUN complete — no changes were made."
    else
        print "✅ Adobe Toggle Manager has been uninstalled."
    fi
    [[ -n "$BACKUP_TARGET" ]] && print "   Logs backup: $BACKUP_TARGET"
    print "   Source repo unchanged: $SCRIPT_DIR"
    print
    print "Optional: delete the source repo with:"
    print "   /bin/rm -rf $SCRIPT_DIR"
}

# === Orchestrator =======================================================
main() {
    print "Adobe Toggle v4 Uninstaller"
    print "App-Support:    $APP_SUPPORT"
    print "LaunchAgents:   $PLIST_PATH"
    print "                $HEALTHCHECK_PLIST_PATH"
    (( DRY_RUN ))      && print "Mode:           DRY-RUN (no changes)"
    (( FORCE ))        && print "Mode:           FORCE (no-prompt)"
    (( SKIP_RELEASE )) && print "Mode:           SKIP_RELEASE (Adobe stays blocked!)"

    local phase
    for phase in confirm release_adobe backup_logs bootout kill_processes \
                 plists appsupport src_symlink summary; do
        print
        print "→ Phase: $phase"
        if ! "phase_${phase}"; then
            print -u2 -- "Phase '$phase' failed or was aborted."
            return 1
        fi
    done
}

# Source guard (memory standard for zsh Adobe-Toggle modules)
if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file ]]; then
    main "$@"
fi
