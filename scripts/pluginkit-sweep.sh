#!/bin/zsh
# === Adobe Pluginkit Sweep ===
# DEPRECATION-NOTE (v4.3.0): This functionality has been natively integrated
# into the daemon (lib/backends/pluginkit.zsh) as a second backend since v4.3.0.
# The daemon blocks/allows pluginkit extensions automatically on the
# 30-second tick — no manual sweep needed anymore.
#
# Helper remains functional for:
#   - one-shot use without an installed daemon
#   - manual status check (`status` subcommand)
#   - overriding the daemon behavior (e.g. `allow` while the daemon is in
#     block state — gets re-blocked on the next tick)
#
# === Adobe Pluginkit Sweep — Original Description ===
# Companion to adobe-toggle — blocks Adobe pluginkit extensions
# (FinderSync, ContextMenu, QuickLook) that the launchd-based daemon does
# NOT cover. Pluginkit extensions live in a separate macOS subsystem DB
# and are instantiated on-demand by the system.
#
# Usage:
#   ./pluginkit-sweep.sh           → block (default, idempotent)
#   ./pluginkit-sweep.sh block     → ignore all Adobe extensions
#   ./pluginkit-sweep.sh allow     → use all Adobe extensions
#   ./pluginkit-sweep.sh status    → list Adobe extensions + state
#   ./pluginkit-sweep.sh kill      → kill running Adobe extension processes
#
# Exit codes: 0=ok, 1=usage error, 2=pluginkit not available
#
# Rationale: Adobe app updates can reset the ignore state. Therefore run this
# as a recurring sweep step after updates.

set -u
emulate -L zsh
setopt NO_UNSET PIPE_FAIL

# Absolute paths against PATH hijacking (analogous to L-2 in adobe-toggle).
# Test override hooks (analogous to the v4 pattern): ATM_*_BIN env vars override
# defaults for isolated tests, WITHOUT weakening PATH hardening.
typeset -gr PLUGINKIT_BIN="${ATM_PLUGINKIT_BIN:-/usr/bin/pluginkit}"
typeset -gr GREP_BIN="${ATM_GREP_BIN:-/usr/bin/grep}"
typeset -gr AWK_BIN="${ATM_AWK_BIN:-/usr/bin/awk}"
typeset -gr PS_BIN="${ATM_PS_BIN:-/bin/ps}"
typeset -gr KILL_BIN="${ATM_KILL_BIN:-/bin/kill}"

# Hard guard analogous to ATM_LAUNCHCTL_REAL_DENY: blocks Adobe operations on
# the real pluginkit if tests forget to mock it. Set =1 in sandbox.
typeset -gr ATM_PLUGINKIT_REAL_DENY="${ATM_PLUGINKIT_REAL_DENY:-0}"

# Store the script path once: in zsh, `$0` inside a function is the function
# name (FUNCTION_ARGZERO default ON), not the script path. The top-level `$0`
# is the path on direct execve. In sourced context, `${(%):-%x}` is the path
# to the current file.
typeset -gr SCRIPT_PATH="${${(%):-%x}:A}"

[[ -x "$PLUGINKIT_BIN" ]] || { print -u2 -- "FATAL: $PLUGINKIT_BIN not executable"; exit 2; }

_pluginkit() {
    if [[ "$ATM_PLUGINKIT_REAL_DENY" == "1" && "$PLUGINKIT_BIN" == "/usr/bin/pluginkit" ]]; then
        local arg
        for arg in "$@"; do
            if [[ "$arg" == *com.adobe.* ]]; then
                print -u2 -- "FATAL: ATM_PLUGINKIT_REAL_DENY=1 — refusing real pluginkit with com.adobe.*: $arg"
                return 99
            fi
        done
    fi
    "$PLUGINKIT_BIN" "$@"
}

_list_adobe_extensions() {
    # pluginkit -m -A -v output: <state><spaces>bundle(version)\tUUID\tdate\tpath
    # state: '+' = enabled, '-' = ignored, ' ' = neither (system default)
    # Output (tab-separated): <state>\t<bundle-id>\t<path>
    # LOCAL_OPTIONS NO_PIPE_FAIL: the legitimate edge case "no Adobe extensions
    # installed" makes grep exit with 1 — that is NOT an error. Without
    # NO_PIPE_FAIL the whole pipeline would return exit 1.
    setopt LOCAL_OPTIONS NO_PIPE_FAIL
    _pluginkit -m -A -v 2>/dev/null \
        | "$GREP_BIN" -i adobe \
        | "$AWK_BIN" 'BEGIN{FS="\t"} {
            state = substr($0, 1, 1);
            bundle = $1;
            sub(/^[+\- ][ ]+/, "", bundle);
            sub(/\([^)]*\)$/, "", bundle);
            path = $NF;
            printf "%s\t%s\t%s\n", state, bundle, path;
        }'
}

_status() {
    print -- "Adobe pluginkit extensions (state: + enabled, - ignored, blank default):"
    _list_adobe_extensions | "$AWK_BIN" -F'\t' '{ printf "  [%s] %-65s %s\n", $1, $2, $3 }'
}

_apply() {
    local action="$1"   # ignore | use
    local count_changed=0 count_total=0
    # NOTE: `path` is a zsh special variable (array mirror of $PATH). `local path`
    # + `read -r ... path` triggers a silent failure of the read loop. Hence bundle_path.
    local state bundle bundle_path
    while IFS=$'\t' read -r state bundle bundle_path; do
        [[ -z "$bundle" ]] && continue
        ((count_total++))
        if [[ "$action" == "ignore" && "$state" == "-" ]]; then
            print -- "  skip (already ignored): $bundle"
            continue
        fi
        if [[ "$action" == "use" && "$state" == "+" ]]; then
            print -- "  skip (already enabled): $bundle"
            continue
        fi
        if _pluginkit -e "$action" -i "$bundle" 2>/dev/null; then
            print -- "  $action → $bundle"
            ((count_changed++))
        else
            print -u2 -- "  FAIL ($action): $bundle"
        fi
    done < <(_list_adobe_extensions)
    print -- "Done: $count_changed of $count_total Adobe extensions changed."
}

_kill_running() {
    local pids
    pids=$("$PS_BIN" -axo pid,command \
        | "$GREP_BIN" -iE "Adobe.*\.appex/Contents/MacOS" \
        | "$GREP_BIN" -v grep \
        | "$AWK_BIN" '{print $1}')
    if [[ -z "$pids" ]]; then
        print -- "No Adobe pluginkit-extension processes running."
        return 0
    fi
    local pid
    for pid in ${(f)pids}; do
        print -- "  kill -TERM $pid"
        "$KILL_BIN" -TERM "$pid" 2>/dev/null || print -u2 -- "    FAIL kill $pid"
    done
    sleep 1
    # Re-check + escalate to KILL if still alive
    for pid in ${(f)pids}; do
        if "$PS_BIN" -p "$pid" >/dev/null 2>&1; then
            print -- "  kill -KILL $pid (escalation)"
            "$KILL_BIN" -KILL "$pid" 2>/dev/null
        fi
    done
}

main() {
    local cmd="${1:-block}"
    case "$cmd" in
        block)
            _apply ignore
            _kill_running
            print --
            _status
            ;;
        allow)
            _apply use
            print --
            _status
            ;;
        status)
            _status
            ;;
        kill)
            _kill_running
            ;;
        -h|--help|help)
            "$AWK_BIN" '/^# /{ sub(/^# ?/, ""); print } /^$/{ exit }' "$SCRIPT_PATH"
            ;;
        *)
            print -u2 -- "Unknown command: $cmd (use: block | allow | status | kill | help)"
            exit 1
            ;;
    esac
}

# Source guard (analogous to the v4 pattern): only execute on direct invocation
[[ "${ZSH_EVAL_CONTEXT:-}" != *:file ]] && main "$@"
