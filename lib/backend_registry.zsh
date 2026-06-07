#!/bin/zsh
# === Backend Registry (v4.3.0) ===
# Manages discovery backends (launchd, pluginkit, …) for the daemon.
# See lib/backends/_interface.zsh for the spec.

# Required functions that every backend must implement.
typeset -gar _BACKEND_REQUIRED_FUNCTIONS=( name discover block allow is_blocked kill_running )

# Registry state: name → source file
typeset -gA _BACKENDS
# Registration order (matters for discovery + block priority).
typeset -ga _BACKEND_ORDER

# === backend_register <name> <file> ===
# Sources the backend file and checks conformance (all 6 required functions
# exist in the <name>__ namespace). On failure: not registered,
# return 1 + log_error.
backend_register() {
    local name="$1" file="$2"
    if [[ -z "$name" || -z "$file" ]]; then
        print -u2 -- "backend_register: usage: backend_register <name> <file>"
        return 1
    fi
    # Name validation: lowercase, [a-z0-9_]
    if [[ ! "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
        print -u2 -- "backend_register: invalid name '$name' (must match ^[a-z][a-z0-9_]*$)"
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        print -u2 -- "backend_register: file not found: $file"
        return 1
    fi
    # Re-registration: idempotent overwrite (re-source).
    if [[ -n "${_BACKENDS[$name]:-}" ]]; then
        print -u2 -- "backend_register: re-registering '$name' (was: ${_BACKENDS[$name]})"
    fi
    if ! source "$file"; then
        print -u2 -- "backend_register: source failed: $file"
        return 1
    fi
    # Conformance check.
    local fn missing=()
    for fn in "${_BACKEND_REQUIRED_FUNCTIONS[@]}"; do
        (( $+functions[${name}__${fn}] )) || missing+=( "${name}__${fn}" )
    done
    if (( ${#missing[@]} > 0 )); then
        print -u2 -- "backend_register: '$name' missing functions: ${missing[*]}"
        return 1
    fi
    _BACKENDS[$name]="$file"
    # Order: only the first occurrence — on re-register the position stays.
    if ! (( ${_BACKEND_ORDER[(I)$name]} )); then
        _BACKEND_ORDER+=( "$name" )
    fi
    return 0
}

# === backend_unregister <name> ===
# Removes from the registry. Functions in the global namespace remain (no
# clean zsh method to remove them). Mainly for tests.
backend_unregister() {
    local name="$1"
    [[ -z "$name" ]] && { print -u2 -- "backend_unregister: missing name"; return 1; }
    [[ -z "${_BACKENDS[$name]:-}" ]] && return 1
    unset "_BACKENDS[$name]"
    _BACKEND_ORDER=( "${(@)_BACKEND_ORDER:#$name}" )
    return 0
}

# === backend_list ===
# Prints backend names in registration order, one per line.
backend_list() {
    local b
    for b in "${_BACKEND_ORDER[@]}"; do
        print -- "$b"
    done
}

# === backend_count ===
# Number of registered backends.
backend_count() {
    print -- "${#_BACKEND_ORDER[@]}"
}

# === backend_is_registered <name> ===
# Exit 0 if registered, otherwise 1.
backend_is_registered() {
    local name="$1"
    [[ -n "${_BACKENDS[$name]:-}" ]]
}

# === backend_dispatch <name> <fn> [args...] ===
# Calls <name>__<fn> with the remaining arguments.
# Backend must be registered, the function must exist.
backend_dispatch() {
    local name="$1" fn="$2"
    shift 2
    if ! backend_is_registered "$name"; then
        print -u2 -- "backend_dispatch: not registered: $name"
        return 127
    fi
    if ! (( $+functions[${name}__${fn}] )); then
        print -u2 -- "backend_dispatch: function not found: ${name}__${fn}"
        return 127
    fi
    "${name}__${fn}" "$@"
}

# === backend_discover_all ===
# Iterates over all registered backends in registration order,
# calls <name>__discover and prefixes each output line with the backend name.
# Output: TSV lines  backend\ttype\tidentifier\tscope\tpath
# Backend discover failures are logged (if log_warn is available)
# but do NOT interrupt the entire sweep.
backend_discover_all() {
    local b line
    for b in "${_BACKEND_ORDER[@]}"; do
        # If discover fails, move on to the next backend.
        if ! "${b}__discover" 2>/dev/null | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            print -- "${b}\t${line}"
        done; then
            (( $+functions[log_warn] )) && log_warn "backend $b discover failed"
        fi
    done
}
