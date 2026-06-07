#!/bin/zsh
# === lib/whitelist.zsh — Whitelist Manager (v4.8.0) ===
# Module responsibility: TUI fzf picker for per-component state.
#
# UX:
#   1. List of all discovered items with current state marker
#   2. fzf --multi: TAB toggles selection, ENTER confirms
#   3. Each selected item gets its state toggled:
#        - State == user_allowed → state := auto_blocked (un-whitelist)
#        - State != user_allowed → state := user_allowed (whitelist)
#
# Dependencies: disabled_list (get_state, set_state), global ATM_DISCOVERED_FILE.
# fzf is checked at runtime (clear error message when missing).

# v4.14.2 (hot-fix): fzf lookup in known Brew paths instead of PATH search.
# H-4 (v4.0.0) hardened PATH to system binaries — Homebrew paths are not
# included, so `command -v fzf` would yield a false negative even when fzf
# is installed. Search explicitly in Apple Silicon + Intel + user-local paths.
# v4.14.3: ATM_FZF_BIN override for tests (analogous to ATM_LAUNCHCTL_BIN pattern).
_find_fzf() {
    if [[ -n "${ATM_FZF_BIN:-}" && -x "${ATM_FZF_BIN}" ]]; then
        print -- "${ATM_FZF_BIN}"
        return 0
    fi
    local p
    for p in /opt/homebrew/bin/fzf /usr/local/bin/fzf "$HOME/.local/bin/fzf"; do
        [[ -x "$p" ]] && { print -- "$p"; return 0; }
    done
    return 1
}

# whitelist_main — entry point for TUI [w] action
whitelist_main() {
    local fzf_bin
    fzf_bin=$(_find_fzf) || {
        print -u2 -- "❌ fzf is not installed. Install: brew install fzf"
        print -u2 -- "    (searched in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)"
        return 1
    }
    if [[ ! -f "$ATM_DISCOVERED_FILE" ]]; then
        print -u2 -- "❌ discovered.list missing — daemon may not be running yet."
        return 1
    fi

    # Build fzf input: TAB-separated marker + label + scope + type + path.
    # --with-nth shows only 1-3; label and path stay in the selected string
    # for subsequent parsing.
    local _t label _path scope state marker
    local -a fzf_lines
    while IFS=$'\t' read -r _t label _path scope; do
        [[ -z "$label" ]] && continue
        state=$(disabled_list_get_state "$label" 2>/dev/null) || state=""
        # if/elif instead of case: zsh sometimes interprets case patterns as
        # globs (especially with NO_UNSET + empty state) → "bad pattern: (" error.
        if [[ "$state" == "user_allowed" ]]; then
            marker="🟢 ALLOWED      "
        elif [[ "$state" == "user_blocked" ]]; then
            marker="🔴 BLOCKED-USER "
        elif [[ "$state" == "auto_blocked" ]]; then
            marker="⚫ blocked-auto "
        else
            marker="⚪ none         "
        fi
        # Format: marker | label | scope | type | path (TAB-sep)
        # Square brackets instead of parentheses to work around zsh glob context bug
        local scope_display="[scope=${scope}]"
        local type_display="[type=${_t}]"
        fzf_lines+=( "${marker}"$'\t'"${label}"$'\t'"${scope_display}"$'\t'"${type_display}" )
    done < "$ATM_DISCOVERED_FILE"

    if (( ${#fzf_lines[@]} == 0 )); then
        print -u2 -- "❌ No discovered components."
        return 1
    fi

    local selected
    selected=$(printf '%s\n' "${fzf_lines[@]}" | "$fzf_bin" \
        --multi \
        --delimiter=$'\t' \
        --with-nth=1,2,3,4 \
        --header="TAB=select  ENTER=toggle whitelist  ESC=cancel" \
        --prompt="Whitelist > " \
        --height=80% \
        --reverse) || { print "(cancelled)"; return 0; }
    [[ -z "$selected" ]] && { print "(nothing selected)"; return 0; }

    # Apply: toggle state for each selected item.
    local line _marker lbl scope_field _type new_state current
    local -i toggled=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r _marker lbl scope_field _type <<<"$line"
        # scope_field is "[scope=gui]" — strip prefix + suffix
        # zsh ${var#pattern} interprets ( as glob-group-open → backslash escape
        local scope="${scope_field#\[scope=}"
        scope="${scope%\]}"
        current=$(disabled_list_get_state "$lbl" 2>/dev/null) || current=""
        if [[ "$current" == "user_allowed" ]]; then
            new_state="auto_blocked"
        else
            new_state="user_allowed"
        fi
        if disabled_list_set_state "$lbl" "$scope" "$new_state"; then
            print "  ✓ ${lbl} (${scope}): ${current:-none} → ${new_state}"
            toggled=$(( toggled + 1 ))
        else
            print -u2 -- "  ✗ ${lbl}: set_state failed"
        fi
    done <<<"$selected"

    print
    print "→ ${toggled} component(s) state-toggled."
    print "  The daemon's block action respects user_allowed entries from the next tick onward."
    return 0
}
