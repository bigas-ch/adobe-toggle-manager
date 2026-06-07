#!/usr/bin/env bats
# Lean-state (v1.1.0): curated bloat classification (lib/bloat.zsh).
# All Adobe components share one codesign authority, so "bloat vs essential"
# CANNOT come from the signature — _is_bloat is the curated classification
# layer. Conservative posture: only labels/paths matching ATM_BLOAT_PATTERNS
# count as bloat; everything else (incl. unknown/new) is treated as essential
# so a licensed app never breaks.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "_is_bloat matches a known bloat label" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _is_bloat 'com.adobe.CCXProcess' '/x' && echo HIT"
    [ "$output" = "HIT" ]
}

@test "_is_bloat does NOT match a non-bloat label" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _is_bloat 'com.adobe.AdobeCreativeCloud' '/x' && echo HIT || echo MISS"
    [ "$output" = "MISS" ]
}

@test "_is_bloat matches by path when label is generic" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _is_bloat 'com.adobe.generic' '/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app' && echo HIT"
    [ "$output" = "HIT" ]
}

@test "_is_bloat is case-insensitive" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _is_bloat 'COM.ADOBE.ccxPROCESS' '/x' && echo HIT"
    [ "$output" = "HIT" ]
}

# T8 real-install tuning (2026-06-07): the Adobe Genuine GC client (AdobeGCClient,
# spawned by com.adobe.GC.Scheduler-1.0 / GC.Invoker) was kept running by lean and
# consumed ~31% CPU on a verified licensed install. GC = Adobe Genuine anti-piracy;
# for a licensed user it is background bloat → curated into the bloat list.
@test "_is_bloat matches the Adobe Genuine GC scheduler launchd agent" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _is_bloat 'com.adobe.GC.Scheduler-1.0' '/Library/LaunchAgents/com.adobe.GC.Invoker-1.0.plist' && echo HIT"
    [ "$output" = "HIT" ]
}

@test "_is_bloat matches the AdobeGCClient Genuine process" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _is_bloat 'com.adobe.acc.AdobeGCClient' '/Library/Application Support/Adobe/AdobeGCClient/AdobeGCClient' && echo HIT"
    [ "$output" = "HIT" ]
}

@test "_is_bloat does NOT match AdobeResourceSynchronizer (essential app helper)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _is_bloat 'com.adobe.ResourceSynchronizer' '/Applications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Helpers/AdobeResourceSynchronizer.app/Contents/MacOS/AdobeResourceSynchronizer' && echo HIT || echo MISS"
    [ "$output" = "MISS" ]
}

# --- _is_lean_blocked predicate (design 3.3) -----------------------------
# In lean, a component is blocked iff:
#   (_is_bloat OR state==user_blocked) AND state != user_allowed
# i.e. shipped bloat OR user-marked-off are blocked; user_allowed always
# rescues (wins over a bloat match); unknown/non-bloat keeps running.

# Seed a per-component state into disabled.list, then query the predicate.
# disabled_list_set_state arg order is: <label> <scope> <state>.
_lean_predicate() { # <label> <scope> <state>
    zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        disabled_list_set_state '$1' '$2' '$3' 2>/dev/null
        _is_lean_blocked '$1' '$2' && echo BLOCK || echo KEEP
    "
}

@test "lean: bloat + no explicit state → BLOCK" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _is_lean_blocked 'com.adobe.CCXProcess' 'gui' && echo BLOCK || echo KEEP"
    [ "$output" = "BLOCK" ]
}

@test "lean: non-bloat + no explicit state (unknown) → KEEP" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _is_lean_blocked 'com.adobe.AcrobatLicensing' 'gui' && echo BLOCK || echo KEEP"
    [ "$output" = "KEEP" ]
}

@test "lean: bloat + user_allowed → KEEP (user rescue overrides bloat)" {
    run _lean_predicate com.adobe.CCXProcess gui user_allowed
    [ "$output" = "KEEP" ]
}

@test "lean: non-bloat + user_blocked → BLOCK (user marked it off)" {
    run _lean_predicate com.adobe.AcrobatLicensing gui user_blocked
    [ "$output" = "BLOCK" ]
}

@test "lean: bloat + user_blocked → BLOCK" {
    run _lean_predicate com.adobe.CCXProcess gui user_blocked
    [ "$output" = "BLOCK" ]
}

@test "lean: non-bloat + user_allowed → KEEP" {
    run _lean_predicate com.adobe.AcrobatLicensing gui user_allowed
    [ "$output" = "KEEP" ]
}
