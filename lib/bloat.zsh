#!/bin/zsh
# === lib/bloat.zsh — Curated bloat classification for the lean state (v1.1.0) ===
# Module responsibility: decide whether a discovered Adobe component is "bloat"
# (safe to disable in lean) vs "essential" (kept running). All Adobe components
# share one codesign authority, so the split CANNOT come from the signature —
# this curated list is the classification layer.
#
# Conservative posture (design 2026-06-07): lean blocks ONLY what matches here
# (or what the user explicitly marked user_blocked); everything else, including
# unknown/new components, keeps running so a licensed app never breaks.
#
# Dependencies: disabled_list (disabled_list_get_state) — sourced before this.

# Label/path substrings (lowercased compare) classified as background bloat.
# ⚠️ CANDIDATE LIST — VERIFY against a real licensed Adobe install (T8) before
# trusting aggressively. Adding too much risks breaking app launch/licensing.
typeset -gra ATM_BLOAT_PATTERNS=(
    "ccxprocess"                 # Creative Cloud Experience helper
    "core sync"                  # CoreSync file-sync daemon
    "coresync"
    "adobeipcbroker"             # inter-process broker
    "ipcbox"
    "armdc"                      # Adobe Remote Update Manager / auto-updater
    "genuine"                    # Adobe Genuine integrity service
    "ags_service"                # Adobe Genuine Software service
    "cc content manager"         # Creative Cloud content sync
    "cccontentmanager"
    "creative cloud content"
    "crashreporter"              # crash telemetry
    "crash reporter"
    "adobecrashprocessor"
    "telemetry"
    "auto-updater"
    "autoupdater"
)

# _is_bloat <label> <path> → 0 if the component is classified bloat, else 1.
# Case-insensitive substring match against ATM_BLOAT_PATTERNS over "label path".
# Empty list = nothing is bloat (lean blocks nothing → safe).
_is_bloat() {
    local label="${1:-}" path="${2:-}"
    (( ${#ATM_BLOAT_PATTERNS[@]} == 0 )) && return 1
    local hay="${label:l} ${path:l}"
    local pat
    for pat in "${ATM_BLOAT_PATTERNS[@]}"; do
        [[ "$hay" == *"${pat}"* ]] && return 0
    done
    return 1
}

# _is_lean_blocked <label> <scope> → 0 if this component should be disabled in
# the lean state, else 1. Reuses the existing per-component disabled.list
# states instead of a new schema:
#   block iff (_is_bloat OR state==user_blocked) AND state != user_allowed.
# user_allowed always wins (essential rescue, v4.8.0). The component path is
# looked up from discovered.list when available so the bloat match can also key
# on the path (best-effort; works on label alone if the file is absent).
_is_lean_blocked() {
    local label="${1:-}" scope="${2:-}"
    [[ -z "$label" ]] && return 1
    local state=""
    if (( ${+functions[disabled_list_get_state]} )); then
        state=$(disabled_list_get_state "$label" 2>/dev/null) || state=""
    fi
    [[ "$state" == "user_allowed" ]] && return 1   # user rescue wins over bloat
    [[ "$state" == "user_blocked" ]] && return 0   # user marked it off
    local path="" tab=$'\t'
    if [[ -f "$ATM_DISCOVERED_FILE" ]]; then
        path=$(/usr/bin/grep -F -- "${tab}${label}${tab}" "$ATM_DISCOVERED_FILE" 2>/dev/null \
               | /usr/bin/head -1 | /usr/bin/cut -f3)
    fi
    _is_bloat "$label" "$path"
}
