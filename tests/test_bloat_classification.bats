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
