#!/bin/zsh
# === lib/pam.zsh — Touch-ID-for-sudo detection + sudo-sweep for system daemons ===
# Module responsibility: Touch-ID auth via pam_tid.so, on-demand sudo-sweep for
# system-scope Adobe LaunchDaemons (which the user-mode daemon cannot disable).
#
# Dependencies: log, disabled_list (disabled_list_add), notify, discovery
# (discover_plists), globals ATM_PAM_SUDO_FILE, ATM_PAM_SUDO_LOCAL_FILE,
# ATM_LAUNCHCTL_BIN.

# QW-7: source of system-scope launchd labels for the sudo-sweep paths.
# Reuses the daemon-maintained discovered.list (via _read_discovered_by_type
# launchd in discovery.zsh) instead of calling discover_plists directly — so a
# held [b] no longer triggers full live discovery ~3×/sec. Live-discovery
# fallback when discovered.list is missing OR empty (test contexts + cold start
# before the first discovery_sweep tick); _read_discovered_by_type already
# falls back when the file is missing, this adds the empty-file case.
_sweep_launchd_source() {
    if [[ -s "$ATM_DISCOVERED_FILE" ]]; then
        _read_discovered_by_type launchd
        return 0
    fi
    discover_plists
}

# === Sudo-sweep: disable system LaunchDaemons (Touch-ID enforced) ===
# Checks whether pam_tid.so is active for sudo. If yes → sudo directly (Touch-ID
# prompt appears). If no → notice + instructions, no fallback to password.
_touchid_for_sudo_enabled() {
    /usr/bin/grep -qE -- "^auth.*pam_tid\.so" "${ATM_PAM_SUDO_FILE}" 2>/dev/null && return 0
    /usr/bin/grep -qE -- "^auth.*pam_tid\.so" "${ATM_PAM_SUDO_LOCAL_FILE}" 2>/dev/null && return 0
    return 1
}

sudo_sweep_action() {
    # Collect system-scope Adobe LaunchDaemons from the current discovery
    local _t label _p scope
    local -a system_labels=()
    while IFS=$'\t' read -r _t label _p scope; do
        [[ "$scope" == "system" && -n "$label" ]] && system_labels+=( "$label" )
    done < <(_sweep_launchd_source)

    if (( ${#system_labels[@]} == 0 )); then
        print "→ No system-scope Adobe LaunchDaemons found. Nothing to do."
        return 0
    fi

    if ! _touchid_for_sudo_enabled; then
        print
        print "❌ Touch ID for /usr/bin/sudo is not enabled."
        print
        print "  Enable it with (one-time):"
        print "    /usr/bin/sudo /bin/cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local"
        print "    /usr/bin/sudo /usr/bin/sed -i '' 's|^# *auth|auth|' /etc/pam.d/sudo_local"
        print
        print "  Then retry the sudo-sweep."
        return 1
    fi

    print
    print "The following system-scope LaunchDaemons will be disabled via /usr/bin/sudo:"
    local lbl
    for lbl in "${system_labels[@]}"; do
        print "  • $lbl"
    done
    print
    printf "Continue? (Touch-ID prompt appears) [y/N]: "
    local confirm
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print "Aborted."; return 0; }

    # Sudo directly: pam_tid.so triggers Touch-ID auth instead of a password.
    # `sudo -v` → caches creds for 5 min, then sudo calls without re-auth.
    print "→ Touch-ID authentication required..."
    if ! _sudo -v; then
        print "→ ❌ Touch-ID authentication failed or was cancelled."
        return 1
    fi

    # Run the disables (with cached sudo credentials)
    local fail=0
    for lbl in "${system_labels[@]}"; do
        _sudo "${ATM_LAUNCHCTL_BIN}" bootout "system/${lbl}" 2>/dev/null
        if _sudo "${ATM_LAUNCHCTL_BIN}" disable "system/${lbl}" 2>/dev/null; then
            disabled_list_add "$lbl" "system"
            log_event DISABLED "${lbl}:system"
        else
            log_warn "/usr/bin/sudo /bin/launchctl disable failed for $lbl"
            fail=$(( fail + 1 ))
        fi
    done

    local ok=$(( ${#system_labels[@]} - fail ))
    if (( fail == 0 )); then
        print "→ ✅ ${ok} System-LaunchDaemons disabled."
        notify "Adobe Toggle" "Sudo-Sweep: ${ok} system-LaunchDaemons disabled."
    else
        print "→ ⚠️ ${ok} disabled, ${fail} failed."
        notify "Adobe Toggle" "Sudo-Sweep: ${ok} ok, ${fail} fail"
    fi
}

# === Sudo-unsweep: enable system LaunchDaemons (allow counterpart to the sweep) ===
# v4.19.0: counterpart to sudo_sweep_action. Without this function, system-scope
# Adobe LaunchDaemons (Genuine, ARMDC, acc.installer.v2) stay permanently disabled
# even after a state change to 'allow' — because enable_launchd_label() in
# discovery.zsh is a no-op for scope=system (no sudo in the user-mode daemon).
#
# Consequence without unsweep: in allow mode Adobe apps start, but the genuine
# check and update paths break → apps refuse functions or crash (e.g. Acrobat).
# Hence this TUI-triggered sudo-sweep after allow.
sudo_unsweep_action() {
    if [[ ! -f "$ATM_DISABLED_FILE" ]]; then
        print "→ disabled.list is empty. Nothing to enable."
        return 0
    fi

    # Collect system-scope labels from disabled.list, SKIPPING user_allowed
    # (the user explicitly marked the item as blocked — whitelist persistence, cf.
    # allow_action() in discovery.zsh).
    local label scope ts state
    local -a system_labels=()
    while IFS=$'\t' read -r label scope ts state; do
        [[ -z "$label" ]] && continue
        [[ "$scope" != "system" ]] && continue
        [[ "$state" == "user_allowed" ]] && continue
        system_labels+=( "$label" )
    done < "$ATM_DISABLED_FILE"

    if (( ${#system_labels[@]} == 0 )); then
        print "→ No system-scope entries in disabled.list. Nothing to enable."
        return 0
    fi

    if ! _touchid_for_sudo_enabled; then
        print
        print "❌ Touch ID for /usr/bin/sudo is not enabled."
        print
        print "  Enable it with (one-time):"
        print "    /usr/bin/sudo /bin/cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local"
        print "    /usr/bin/sudo /usr/bin/sed -i '' 's|^# *auth|auth|' /etc/pam.d/sudo_local"
        print
        print "  Then retry the sudo-unsweep."
        return 1
    fi

    print
    print "The following system-scope LaunchDaemons will be enabled via /usr/bin/sudo:"
    local lbl
    for lbl in "${system_labels[@]}"; do
        print "  • $lbl"
    done
    print
    printf "Continue? (Touch-ID prompt appears) [y/N]: "
    local confirm
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print "Aborted."; return 0; }

    print "→ Touch-ID authentication required..."
    if ! _sudo -v; then
        print "→ ❌ Touch-ID authentication failed or was cancelled."
        return 1
    fi

    # Enable + bootstrap. Bootstrap only when the plist lives under an allowed path
    # (analogous to _validate_plist_path in discovery.zsh — inline here for
    # system-scope: /Library/LaunchDaemons/<label>.plist). Soft-fail if already loaded.
    local fail=0 enabled=0
    for lbl in "${system_labels[@]}"; do
        if _sudo "${ATM_LAUNCHCTL_BIN}" enable "system/${lbl}" 2>/dev/null; then
            enabled=$(( enabled + 1 ))
            local plist="/Library/LaunchDaemons/${lbl}.plist"
            if [[ -f "$plist" ]]; then
                _sudo "${ATM_LAUNCHCTL_BIN}" bootstrap system "$plist" 2>/dev/null || true
            fi
            log_event ENABLED "${lbl}:system"
        else
            log_warn "/usr/bin/sudo /bin/launchctl enable failed for $lbl"
            fail=$(( fail + 1 ))
        fi
    done

    # Clean up disabled.list: remove all successfully enabled system entries;
    # user_allowed stays; gui|user scope unchanged.
    local tmp="${ATM_DISABLED_FILE}.tmp.$$"
    : > "$tmp"
    while IFS=$'\t' read -r label scope ts state; do
        [[ -z "$label" ]] && continue
        if [[ "$scope" == "system" && "$state" != "user_allowed" ]]; then
            # Only drop when the label is in our success set — on fail it stays
            # on the list, otherwise drift versus the real launchctl state.
            local found=0 ok_lbl
            for ok_lbl in "${system_labels[@]}"; do
                [[ "$ok_lbl" == "$label" ]] && { found=1; break; }
            done
            (( found )) && continue
        fi
        print -- "${label}\t${scope}\t${ts}\t${state}" >> "$tmp"
    done < "$ATM_DISABLED_FILE"
    /bin/mv -f "$tmp" "$ATM_DISABLED_FILE"

    if (( fail == 0 )); then
        print "→ ✅ ${enabled} System-LaunchDaemons enabled."
        notify "Adobe Toggle" "Sudo-Unsweep: ${enabled} system-LaunchDaemons enabled."
    else
        print "→ ⚠️ ${enabled} enabled, ${fail} failed."
        notify "Adobe Toggle" "Sudo-Unsweep: ${enabled} ok, ${fail} fail"
    fi

    # v4.19.1: keep the pending counter consistent with the real disabled.list
    # state. Pending = number of system items still in disabled.list (could not be
    # enabled + user_allowed). live_state_set updates ONLY pending_system, not the
    # daemon counters (heartbeat/ticks/...) — otherwise TUI mode would overwrite
    # the real daemon values here.
    local remaining=0
    if [[ -f "$ATM_DISABLED_FILE" ]]; then
        remaining=$(/usr/bin/awk -F'\t' '$2=="system" && $4!="user_allowed" {n++} END{print n+0}' "$ATM_DISABLED_FILE" 2>/dev/null)
    fi
    _DAEMON_PENDING_SYSTEM=$remaining
    live_state_set pending_system "$remaining"
}

# === Auto-sweep gating (v4.20.0) ===
# The TUI can auto-chain the system-scope sudo-sweep/unsweep straight after a
# block/allow toggle, so the user no longer needs the separate [u]/[e] step.
# Gated by config + a NON-sudo pre-check, so no Touch-ID prompt appears when
# there is nothing to do.

_auto_sudo_sweep_enabled() {
    local v
    v=$(config_get auto-sudo-sweep 2>/dev/null) || v="$DEFAULT_AUTO_SUDO_SWEEP"
    [[ "$v" == "true" ]]
}

# True if at least one discovered system-scope Adobe label is not yet recorded
# as disabled — i.e. a real sudo-sweep would actually change something.
_pending_system_sweep() {
    local _t label _p scope
    while IFS=$'\t' read -r _t label _p scope; do
        [[ "$scope" == "system" && -n "$label" ]] || continue
        if [[ -f "$ATM_DISABLED_FILE" ]] \
            && /usr/bin/grep -qE -- "^${label}"$'\t'"system"$'\t' "$ATM_DISABLED_FILE"; then
            continue
        fi
        return 0
    done < <(_sweep_launchd_source)
    return 1
}

# True if disabled.list holds at least one system-scope, non-user_allowed entry
# — the exact work set sudo_unsweep_action would re-enable.
_pending_system_unsweep() {
    [[ -f "$ATM_DISABLED_FILE" ]] || return 1
    /usr/bin/awk -F'\t' '$2=="system" && $4!="user_allowed" {found=1} END{exit found?0:1}' "$ATM_DISABLED_FILE"
}

# QW-6: count of discovered system-scope labels a sudo-sweep would still disable
# (the work set _pending_system_sweep gates on). Prints a plain integer.
_pending_system_sweep_count() {
    local _t label _p scope n=0
    while IFS=$'\t' read -r _t label _p scope; do
        [[ "$scope" == "system" && -n "$label" ]] || continue
        if [[ -f "$ATM_DISABLED_FILE" ]] \
            && /usr/bin/grep -qE -- "^${label}"$'\t'"system"$'\t' "$ATM_DISABLED_FILE"; then
            continue
        fi
        n=$(( n + 1 ))
    done < <(_sweep_launchd_source)
    print -- "$n"
}

# QW-6: count of system-scope, non-user_allowed entries in disabled.list — the
# work set sudo_unsweep_action would re-enable. Prints a plain integer.
_pending_system_unsweep_count() {
    [[ -f "$ATM_DISABLED_FILE" ]] || { print -- 0; return 0; }
    /usr/bin/awk -F'\t' '$2=="system" && $4!="user_allowed" {n++} END{print n+0}' "$ATM_DISABLED_FILE"
}
