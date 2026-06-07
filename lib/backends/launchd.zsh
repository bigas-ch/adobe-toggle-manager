#!/bin/zsh
# === Backend: launchd (v4.3.0) ===
# Discovery + Block/Allow for macOS LaunchAgents/LaunchDaemons.
# Spec: lib/backends/_interface.zsh
#
# Implementation: thin adapter over the existing functions in
# adobe-toggle (discover_plists, disable_launchd_label,
# enable_launchd_label, kill_adobe_processes). Prerequisite: the main script
# must be sourced BEFORE backend registration.
#
# Item format (per interface spec):
#   type:       "agent" (gui/user scope) | "daemon" (system scope)
#   identifier: launchd label (e.g. "com.adobe.AdobeCreativeCloud")
#   scope:      "gui" | "user" | "system"
#   path:       absolute path to the .plist

launchd__name() {
    print -- "launchd"
}

# Wrapper over the existing discover_plists.
# discover_plists produces: launchd\tlabel\tplist\tscope
# Backend interface expects:  type\tidentifier\tscope\tpath
# → reorder columns + derive type from scope.
launchd__discover() {
    local _backend label plist scope type
    discover_plists | while IFS=$'\t' read -r _backend label plist scope; do
        case "$scope" in
            system)  type="daemon" ;;
            gui|user) type="agent" ;;
            *)       type="unknown" ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$type" "$label" "$scope" "$plist"
    done
}

# Block: delegates to disable_launchd_label.
# Exit codes per backend interface spec:
#   0 = newly blocked
#   1 = already blocked (idempotent skip)
#   2 = needs sudo (system scope, not escalatable in the daemon)
#   3 = hard failure (validation, unknown scope)
launchd__block() {
    local _type="$1" identifier="$2" scope="$3" _path="$4"
    if [[ -z "$identifier" ]]; then
        return 3
    fi
    # Idempotency: already in disabled.list → exit 1 (skip).
    if [[ -f "$ATM_DISABLED_FILE" ]] && \
       /usr/bin/grep -q -- "^${identifier}"$'\t' "$ATM_DISABLED_FILE" 2>/dev/null; then
        return 1
    fi
    case "$scope" in
        gui|user)
            disable_launchd_label "$identifier" "$scope"
            return 0
            ;;
        system)
            # disable_launchd_label logs WARN_NEEDS_SUDO (with its own
            # idempotency check for subsequent ticks). We report 2.
            disable_launchd_label "$identifier" "$scope"
            return 2
            ;;
    esac
    return 3
}

# Allow: delegates to enable_launchd_label.
# Exit codes:
#   0 = re-activated
#   1 = not in disabled state (no-op)
#   2 = needs sudo
#   3 = hard failure
launchd__allow() {
    local _type="$1" identifier="$2" scope="$3" _path="$4"
    if [[ -z "$identifier" ]]; then
        return 3
    fi
    case "$scope" in
        gui|user)
            enable_launchd_label "$identifier" "$scope"
            return 0
            ;;
        system)
            enable_launchd_label "$identifier" "$scope"
            return 2
            ;;
    esac
    return 3
}

# is_blocked: checks whether identifier is listed in disabled.list.
launchd__is_blocked() {
    local _type="$1" identifier="$2" _scope="$3" _path="$4"
    [[ -z "$identifier" ]] && return 2
    [[ -f "$ATM_DISABLED_FILE" ]] || return 1
    /usr/bin/grep -q -- "^${identifier}"$'\t' "$ATM_DISABLED_FILE"
}

# kill_running: launchd processes via Adobe authority match.
# Wrapper over the existing kill_adobe_processes (TERM → KILL escalation).
launchd__kill_running() {
    kill_adobe_processes
    return 0
}
