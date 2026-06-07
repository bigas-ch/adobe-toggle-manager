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
