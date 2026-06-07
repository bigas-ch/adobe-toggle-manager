#!/bin/zsh
# === Adobe Toggle — git-hooks installer (v4.9.0+) ===
# Symlinks scripts/git-hooks/* into .git/hooks/.
# Idempotent: existing hooks are only replaced when they already
# point to scripts/git-hooks/ (protects against overwriting foreign hooks).

set -u
emulate -L zsh
setopt PIPE_FAIL

typeset -gr SCRIPT_DIR="${0:A:h}"
typeset -gr REPO_ROOT="${SCRIPT_DIR:h}"
typeset -gr SRC_HOOKS_DIR="$REPO_ROOT/scripts/git-hooks"
typeset -gr DST_HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [[ ! -d "$REPO_ROOT/.git" ]]; then
    print -u2 -- "❌ Not a git repo at $REPO_ROOT"
    exit 1
fi

[[ -d "$DST_HOOKS_DIR" ]] || /bin/mkdir -p "$DST_HOOKS_DIR"

local hook src dst current
local -i installed=0 skipped=0
for hook in "$SRC_HOOKS_DIR"/*(.N); do
    src="$hook"
    dst="$DST_HOOKS_DIR/${hook:t}"
    if [[ -L "$dst" ]]; then
        current="$(/usr/bin/stat -f '%Y' "$dst" 2>/dev/null)"
        if [[ "$current" == "$src" || "$current" == "../../scripts/git-hooks/${hook:t}" ]]; then
            print "  ✓ ${hook:t} already installed"
            skipped=$(( skipped + 1 ))
            continue
        fi
        print -u2 -- "  ⚠ $dst points to '$current' — skipping (check manually)"
        skipped=$(( skipped + 1 ))
        continue
    elif [[ -e "$dst" ]]; then
        print -u2 -- "  ⚠ $dst exists (not a symlink) — skipping (check manually)"
        skipped=$(( skipped + 1 ))
        continue
    fi
    /bin/ln -s "$src" "$dst" || { print -u2 -- "  ❌ Symlink failed: $dst"; exit 1; }
    print "  ✓ ${hook:t} installed"
    installed=$(( installed + 1 ))
done

print
print "✅ $installed installed, $skipped skipped."
