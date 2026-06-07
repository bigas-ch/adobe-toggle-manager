#!/bin/zsh
# === Adobe Toggle — Test runner with parallel default (v4.10.0+) ===
# Default: bats -j N tests/ where N = nproc or 8 (whichever lower).
# Arguments are passed through to bats (e.g. ./scripts/run-tests.sh tests/test_specific.bats).
#
# Prerequisite for -j: GNU parallel (brew install parallel). If missing,
# we fall back to sequential with a note.

set -u
emulate -L zsh

typeset -gr REPO_ROOT="${0:A:h:h}"

if ! command -v bats >/dev/null 2>&1; then
    print -u2 -- "❌ bats not installed: brew install bats-core"
    exit 1
fi

if ! command -v parallel >/dev/null 2>&1; then
    print -u2 -- "⚠️  GNU parallel not installed (for bats -j) — sequential run:"
    print -u2 -- "    Install: brew install parallel"
    typeset -a SEQ_FILTER_ARGS
    SEQ_FILTER_ARGS=()
    if [[ -n "${CI:-}" && $# -eq 0 ]]; then
        SEQ_FILTER_ARGS=( --filter-tags '!perf' )
        print -u2 -- "    CI detected: excluding perf tests (--filter-tags '!perf')"
    fi
    cd "$REPO_ROOT"
    exec bats "${SEQ_FILTER_ARGS[@]}" "${@:-tests/}"
fi

# Determine cores (M3 Max has 14, common -j recommendation: 8 as the sweet spot
# for I/O-heavy bats tests).
typeset -gi NPROC
NPROC=$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null) || NPROC=8
typeset -gi JOBS=$(( NPROC > 8 ? 8 : NPROC ))

# On CI (GitHub Actions sets CI=true) exclude absolute-time/perf tests:
# the shared macos-14 runner is 3-5x slower than an M3 Max → fixed
# ms thresholds flake. Perf-tag exclusion only when no explicit args
# were passed (a local targeted run stays untouched).
typeset -a FILTER_ARGS
FILTER_ARGS=()
if [[ -n "${CI:-}" && $# -eq 0 ]]; then
    FILTER_ARGS=( --filter-tags '!perf' )
    print "→ CI detected: excluding perf tests (--filter-tags '!perf')"
fi

print "→ bats -j $JOBS ${FILTER_ARGS[*]} ${@:-tests/}"
cd "$REPO_ROOT"
exec bats -j "$JOBS" "${FILTER_ARGS[@]}" "${@:-tests/}"
