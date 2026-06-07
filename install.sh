#!/bin/zsh
# === Adobe Toggle — Installer ===
# Version: 1.1.0 (see CHANGELOG.md; phases: preflight -> appsupport -> copy_scripts -> plist -> bootstrap -> verify -> applauncher)
# 7 phases: preflight → appsupport → copy_scripts → plist → bootstrap → verify → applauncher
# Rollback on failure in any phase (preflight is read-only, no mutation).
#
# Options:
#   ATM_INITIAL_STATE=allow ./install.sh
#       → Set default state to 'allow' (instead of 'block') — useful
#       on first install when Adobe should not be blocked immediately.
#   ATM_BASE=/custom/path ./install.sh
#       → Alternative runtime location (for tests)

set -u
emulate -L zsh
setopt PIPE_FAIL

# H-4: explicit PATH (system binaries only).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# === Security: user-only permissions on newly created files/dirs ===
umask 0077

typeset -gr SRC_DIR="${0:A:h}"
typeset -gr CORE_SRC="$SRC_DIR/adobe-toggle"

typeset -g APP_SUPPORT="${ATM_BASE:-$HOME/Library/Application Support/AdobeToggleManager}"
typeset -g CORE_DST="$APP_SUPPORT/adobe-toggle"
# Cleanup: remove pre-1.0 core paths if still present (v3 → v4 → 1.0 rename to "adobe-toggle")
typeset -ga CORE_DST_OLD=(
    "$APP_SUPPORT/adobe_toggle_v3.sh"
    "$APP_SUPPORT/adobe_toggle_v4.sh"
)
typeset -g LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
typeset -g PLIST_PATH="$LAUNCH_AGENTS/com.user.adobe-toggle.daemon.plist"
typeset -gr LABEL="com.user.adobe-toggle.daemon"
# v4.11.0: healthcheck LaunchAgent (StartInterval=300) for self-healing.
typeset -g HEALTHCHECK_PLIST_PATH="$LAUNCH_AGENTS/com.user.adobe-toggle.healthcheck.plist"
typeset -gr HEALTHCHECK_LABEL="com.user.adobe-toggle.healthcheck"

typeset -ga _PHASES_DONE=()

# === Required inventory (preflight + verify) ===
# All 15 lib/ modules are mandatory — a missing file is soft-sourced
# silently in the core ([[ -f ]] && source), so the daemon then runs with
# undefined functions (e.g. notify, log_event) and only crashes on the
# first call. Preflight prevents that.
typeset -gar REQUIRED_LIB_FILES=(
    log.zsh
    state.zsh
    disabled_list.zsh
    bloat.zsh
    discovery.zsh
    config.zsh
    notify.zsh
    pam.zsh
    tui.zsh
    daemon.zsh
    box.zsh
    watcher.zsh
    backend_registry.zsh
    json.zsh
    whitelist.zsh
)
typeset -gar REQUIRED_BACKEND_FILES=(
    _interface.zsh
    launchd.zsh
    pluginkit.zsh
)
# Test override hooks for CLT-dependent tools (analogous to ATM_CODESIGN_BIN in
# the core, adobe-toggle:57). Default = real system path; tests repoint to
# nonexistent paths to verify graceful degradation.
typeset -g ATM_XCODE_SELECT_BIN="${ATM_XCODE_SELECT_BIN:-/usr/bin/xcode-select}"
typeset -g ATM_CODESIGN_BIN="${ATM_CODESIGN_BIN:-/usr/bin/codesign}"
typeset -g ATM_PLISTBUDDY_BIN="${ATM_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
typeset -g ATM_XCRUN_BIN="${ATM_XCRUN_BIN:-/usr/bin/xcrun}"

# Truly mandatory: guaranteed present on EVERY stock macOS system.
# If these are missing → this is not macOS or a broken system → fatal.
# Deliberately NOT readonly (typeset -ga instead of -gar): the degradation
# tests repoint this list after sourcing to verify the fatal mandatory logic
# (test_installer_preflight_degradation.bats).
typeset -ga MANDATORY_SYSTEM_BINS=(
    /bin/launchctl
    /usr/bin/osascript
    /usr/bin/security
    /usr/bin/sw_vers
    /usr/bin/pluginkit
)
# CLT-dependent: present only with Xcode Command Line Tools. If they are
# missing → a single actionable warning, NO abort. The daemon falls back to
# the 30-s polling fallback instead of FSEvents (codesign/xcrun); PlistBuddy
# is not strictly needed at runtime (plists are written via a cat heredoc,
# see phase_plist).
typeset -gar CLT_DEPENDENT_BINS=(
    "$ATM_CODESIGN_BIN"
    "$ATM_PLISTBUDDY_BIN"
)
typeset -gir MIN_MACOS_MAJOR=14

# === Phase: preflight ===
# Read-only prerequisite check. Writes nothing, no rollback needed
# (not in _PHASES_DONE). Collects ALL errors before aborting — the
# user should see all fixes at once, not iterate over N attempts.
phase_preflight() {
    local -i errors=0 warnings=0

    # ATM_BASE sanity: APP_SUPPORT (derived from ATM_BASE at line 27) is embedded
    # verbatim into the LaunchAgent plists. A non-absolute path would make the
    # daemon create its runtime dir relative to CWD '/' → silent misbehaviour.
    if [[ "$APP_SUPPORT" != /* ]]; then
        print -u2 -- "❌ ATM_BASE must be an absolute path (got: '$APP_SUPPORT')"
        return 1
    fi

    # macOS version
    local macos_ver macos_major
    macos_ver=$(/usr/bin/sw_vers -productVersion 2>/dev/null) || macos_ver=""
    macos_major="${macos_ver%%.*}"
    if [[ "$macos_major" == <-> ]] && (( macos_major >= MIN_MACOS_MAJOR )); then
        print "  ✓ macOS $macos_ver (>= $MIN_MACOS_MAJOR)"
    elif [[ "$macos_major" == <-> ]]; then
        print -u2 -- "  ⚠ macOS $macos_ver (<$MIN_MACOS_MAJOR) — the swift-interpreter pivot targets macOS 14+ library validation; older systems can use a compiled binary via swift/build.sh"
        warnings+=1
    else
        print -u2 -- "  ⚠ macOS version could not be determined"
        warnings+=1
    fi

    # Xcode Command Line Tools (codesign, PlistBuddy, xcrun come from there).
    # A missing CLT is NO longer a hard abort: the daemon runs without FSEvents
    # on the 30-s polling fallback. A single actionable warning is enough.
    local clt_present=0
    if "$ATM_XCODE_SELECT_BIN" -p >/dev/null 2>&1; then
        print "  ✓ Xcode CLT: $("$ATM_XCODE_SELECT_BIN" -p)"
        clt_present=1
    else
        print -u2 -- "  ⚠ Xcode CLT missing — CLT-dependent tools (codesign/PlistBuddy/xcrun) unavailable."
        print -u2 -- "       Daemon uses the 30-s polling fallback instead of FSEvents. Optionally enable:"
        print -u2 -- "       Fix: xcode-select --install"
        warnings+=1
    fi

    # Truly mandatory system binaries — missing = fatal.
    local bin
    for bin in "${MANDATORY_SYSTEM_BINS[@]}"; do
        if [[ -x "$bin" ]]; then
            print "  ✓ $bin"
        else
            print -u2 -- "  ❌ $bin missing or not executable"
            errors+=1
        fi
    done

    # CLT-dependent binaries — missing = WARNING + continue (no abort).
    # If CLT is entirely missing, a warning was already issued above; here we
    # only add a per-tool note without driving the warnings counter again.
    for bin in "${CLT_DEPENDENT_BINS[@]}"; do
        if [[ -x "$bin" ]]; then
            print "  ✓ $bin"
        else
            print -u2 -- "  ⚠ $bin missing — CLT-dependent tool, daemon degrades (30-s polling fallback)."
            (( clt_present == 1 )) && warnings+=1
        fi
    done

    # Source inventory: lib/ + lib/backends/
    local f
    for f in "${REQUIRED_LIB_FILES[@]}"; do
        if [[ -f "$SRC_DIR/lib/$f" ]]; then
            print "  ✓ lib/$f"
        else
            print -u2 -- "  ❌ lib/$f missing in source tree ($SRC_DIR/lib/)"
            errors+=1
        fi
    done
    for f in "${REQUIRED_BACKEND_FILES[@]}"; do
        if [[ -f "$SRC_DIR/lib/backends/$f" ]]; then
            print "  ✓ lib/backends/$f"
        else
            print -u2 -- "  ❌ lib/backends/$f missing in source tree"
            errors+=1
        fi
    done

    # Optional: xcrun swift (event-driven FSEvents watcher instead of 30-s polling)
    if "$ATM_XCRUN_BIN" --find swift >/dev/null 2>&1; then
        print "  ✓ xcrun swift (event-driven FSEvents watcher)"
    else
        print "  ℹ xcrun swift missing — daemon uses the 30-s polling fallback"
    fi

    # Optional: Touch ID for sudo (sudo sweep for system LaunchDaemons)
    if /usr/bin/grep -qE -- "^auth.*pam_tid\.so" /etc/pam.d/sudo 2>/dev/null \
       || /usr/bin/grep -qE -- "^auth.*pam_tid\.so" /etc/pam.d/sudo_local 2>/dev/null; then
        print "  ✓ Touch ID for sudo active (sudo sweep)"
    else
        print "  ℹ Touch ID for sudo inactive — sudo sweep prompts for a password. Optionally enable:"
        print "       sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local"
        print "       sudo sed -i '' 's|^# *auth|auth|' /etc/pam.d/sudo_local"
    fi

    if (( errors > 0 )); then
        print -u2 -- "  → $errors required prerequisite(s) missing — installation aborted."
        return 1
    fi
    (( warnings > 0 )) && print "  → $warnings warning(s), continuing."
    return 0
}

phase_appsupport() {
    /bin/mkdir -p "$APP_SUPPORT/logs" || return 1
    # Security: directories user-only (0700) — even if they were already created with 0755 before v4.0.0
    /bin/chmod 0700 "$APP_SUPPORT" 2>/dev/null
    /bin/chmod 0700 "$APP_SUPPORT/logs" 2>/dev/null
    # Initialize state file with default
    if [[ ! -f "$APP_SUPPORT/state" ]]; then
        local initial="${ATM_INITIAL_STATE:-block}"
        case "$initial" in
            block|allow) print -- "$initial" > "$APP_SUPPORT/state" ;;
            *) print -u2 -- "ATM_INITIAL_STATE must be 'block' or 'allow', not '$initial'"; return 1 ;;
        esac
    fi
    # Existing data files to 0600 (migration for pre-v4.0.0 installs)
    local f
    for f in "$APP_SUPPORT/state" "$APP_SUPPORT/discovered.list" \
             "$APP_SUPPORT/disabled.list" "$APP_SUPPORT/live_state" \
             "$APP_SUPPORT/config"; do
        [[ -f "$f" ]] && /bin/chmod 0600 "$f" 2>/dev/null
    done

    # Source symlink: <repo>/logs/ -> App-Support/logs/ so logs are visible
    # directly from the source path. Only useful in a dev/contributor context
    # (a git working copy). From an extracted release tarball or an arbitrary
    # download dir this would pollute the source tree, so skip it there.
    # Logs always remain under $APP_SUPPORT/logs.
    local src_logs="$SRC_DIR/logs"
    local target="$APP_SUPPORT/logs"
    if [[ ! -d "$SRC_DIR/.git" ]]; then
        print "  ℹ Source tree is not a git working copy — logs symlink skipped. Logs: $target"
    else
        # M-1: TOCTOU-safe symlink setup
        #   1. Check existing symlink target via stat → no-op if already correct
        #   2. Atomic replace via tmp symlink + mv -fh (rename(2) is POSIX-atomic)
        local target_real
        target_real=$(/usr/bin/stat -f "%Y" "$src_logs" 2>/dev/null)
        if [[ -L "$src_logs" && "$target_real" == "$target" ]]; then
            : # symlink already points correctly — no-op (idempotent, race-free)
        elif [[ -L "$src_logs" ]]; then
            local tmp_link="${src_logs}.tmp.$$"
            /bin/rm -f "$tmp_link" 2>/dev/null
            /bin/ln -s "$target" "$tmp_link" || return 1
            /bin/mv -fh "$tmp_link" "$src_logs" || { /bin/rm -f "$tmp_link"; return 1; }
        elif [[ -d "$src_logs" ]]; then
            print -u2 -- "WARN: $src_logs is a real directory, not a symlink. Skipping symlink setup."
        elif [[ -e "$src_logs" ]]; then
            print -u2 -- "WARN: $src_logs exists (file), cannot create a symlink."
        else
            local tmp_link="${src_logs}.tmp.$$"
            /bin/rm -f "$tmp_link" 2>/dev/null
            /bin/ln -s "$target" "$tmp_link" || return 1
            /bin/mv -fh "$tmp_link" "$src_logs" || { /bin/rm -f "$tmp_link"; return 1; }
        fi
    fi
    _PHASES_DONE+=(appsupport)
}

phase_copy_scripts() {
    [[ -f "$CORE_SRC" ]] || { print -u2 -- "Core script not found: $CORE_SRC"; return 1; }
    # Atomic copy via tmp + mv (prevents the KeepAlive daemon from reading a half-copied file)
    local tmp="$CORE_DST.tmp"
    /bin/cp -f "$CORE_SRC" "$tmp" || return 1
    /bin/chmod +x "$tmp" || return 1
    /bin/mv -f "$tmp" "$CORE_DST" || return 1
    # Migration: remove any pre-1.0 core paths if present
    local _old
    for _old in "${CORE_DST_OLD[@]}"; do
        [[ -f "$_old" ]] && /bin/rm -f "$_old"
    done

    # v4.4.0: copy the lib/ tree (modularization) too.
    # The daemon checks ATM_LIB_DIR=$ATM_BASE/lib/ — files MUST be there, otherwise
    # functions stay undefined (hard fail on first call).
    local src_lib="${CORE_SRC:h}/lib"
    local dst_lib="${CORE_DST:h}/lib"
    if [[ -d "$src_lib" ]]; then
        /bin/mkdir -p "$dst_lib/backends" || return 1
        local f
        for f in "$src_lib"/*.zsh(.N); do
            local base="${f:t}"
            /bin/cp -f "$f" "$dst_lib/${base}.tmp" || return 1
            /bin/chmod 0600 "$dst_lib/${base}.tmp" || return 1
            /bin/mv -f "$dst_lib/${base}.tmp" "$dst_lib/$base" || return 1
        done
        for f in "$src_lib"/backends/*.zsh(.N); do
            local base="${f:t}"
            /bin/cp -f "$f" "$dst_lib/backends/${base}.tmp" || return 1
            /bin/chmod 0600 "$dst_lib/backends/${base}.tmp" || return 1
            /bin/mv -f "$dst_lib/backends/${base}.tmp" "$dst_lib/backends/$base" || return 1
        done
        /bin/chmod 0700 "$dst_lib" "$dst_lib/backends"
    fi

    # v4.5.1: copy the atm-watcher.swift source (interpreter mode).
    # v4.5.0 attempted a compile step, but ad-hoc-signed binaries are killed
    # immediately in the LaunchAgent context (macOS 14+ library validation).
    # The Swift interpreter (xcrun swift) bypasses that because swift-frontend
    # is Apple-signed.
    local swift_src="${CORE_SRC:h}/swift/atm-watcher.swift"
    local watcher_swift_dst="${CORE_DST:h}/atm-watcher.swift"
    if [[ -f "$swift_src" ]]; then
        local tmp="$watcher_swift_dst.tmp"
        if /bin/cp -f "$swift_src" "$tmp" 2>/dev/null && \
           /bin/chmod 0600 "$tmp" 2>/dev/null && \
           /bin/mv -f "$tmp" "$watcher_swift_dst" 2>/dev/null; then
            print "  ✓ atm-watcher.swift deployed (interpreter mode via xcrun swift)"
            if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
                print "  ⚠ xcode tools not found (xcode-select --install) — daemon uses the 30-s polling fallback"
            fi
        else
            /bin/rm -f "$tmp" 2>/dev/null
            print "  ⚠ atm-watcher.swift copy failed — daemon uses the 30-s polling fallback"
        fi
        # Cleanup: remove old v4.5.0 binary if present
        local old_binary="${CORE_DST:h}/atm-watcher"
        [[ -f "$old_binary" ]] && /bin/rm -f "$old_binary"
    fi

    _PHASES_DONE+=(copy_scripts)
}

phase_plist() {
    /bin/mkdir -p "$LAUNCH_AGENTS" || return 1
    /bin/cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$CORE_DST</string>
        <string>--daemon</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ATM_BASE</key>
        <string>$APP_SUPPORT</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$APP_SUPPORT/logs/adobe-toggle.daemon.out</string>
    <key>StandardErrorPath</key>
    <string>$APP_SUPPORT/logs/adobe-toggle.daemon.err</string>
</dict>
</plist>
EOF
    # v4.11.0: healthcheck plist (StartInterval=300, no KeepAlive — one-shot per tick)
    /bin/cat > "$HEALTHCHECK_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HEALTHCHECK_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$CORE_DST</string>
        <string>--healthcheck</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ATM_BASE</key>
        <string>$APP_SUPPORT</string>
    </dict>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$APP_SUPPORT/logs/adobe-toggle.healthcheck.out</string>
    <key>StandardErrorPath</key>
    <string>$APP_SUPPORT/logs/adobe-toggle.healthcheck.err</string>
</dict>
</plist>
EOF
    _PHASES_DONE+=(plist)
}

phase_bootstrap() {
    local lbl plist
    for lbl plist in "$LABEL" "$PLIST_PATH" "$HEALTHCHECK_LABEL" "$HEALTHCHECK_PLIST_PATH"; do
        # if already loaded → boot out first + wait until fully booted out
        if /bin/launchctl print "gui/${UID}/${lbl}" >/dev/null 2>&1; then
            /bin/launchctl bootout "gui/${UID}/${lbl}" 2>/dev/null || true
            local i=0
            while (( i < 25 )) && /bin/launchctl print "gui/${UID}/${lbl}" >/dev/null 2>&1; do
                /bin/sleep 0.2
                (( i++ ))
            done
        fi
        /bin/launchctl bootstrap "gui/${UID}" "$plist" || return 1
    done
    _PHASES_DONE+=(bootstrap)
}

phase_verify() {
    # v4.14.1: polling instead of a fixed sleep — under macOS throttling after
    # several daemon crashes, the RunAtLoad spawn can take 5-10s. Plus
    # kickstart as a fallback if "spawn scheduled" is still shown after 3s.
    /bin/sleep 1
    local pid=""
    local i=0
    while (( i < 20 )); do
        pid=$(/bin/launchctl print "gui/${UID}/${LABEL}" 2>/dev/null | /usr/bin/awk '/pid =/ {gsub(/[^0-9]/, "", $3); print $3; exit}')
        [[ -n "$pid" && "$pid" != "0" ]] && break
        # Still no spawn after 3s → force kickstart (bypass throttling)
        if (( i == 6 )); then
            /bin/launchctl kickstart "gui/${UID}/${LABEL}" 2>/dev/null || true
        fi
        /bin/sleep 0.5
        (( i++ ))
    done
    [[ -n "$pid" && "$pid" != "0" ]] || { print -u2 -- "Daemon PID not found via /bin/launchctl print (even after 10s polling + kickstart)"; return 1; }
    [[ -f "$APP_SUPPORT/state" ]] || { print -u2 -- "State file missing: $APP_SUPPORT/state"; return 1; }

    # Verify the lib inventory at the destination — protection against a partial copy
    # (e.g. when copy_scripts crashed mid-loop and the _PHASES_DONE rollback
    # skipped appsupport). preflight checks the source, verify checks the dest.
    local f
    local -i missing=0
    for f in "${REQUIRED_LIB_FILES[@]}"; do
        [[ -f "$APP_SUPPORT/lib/$f" ]] || { print -u2 -- "  ❌ lib/$f missing at destination"; missing+=1; }
    done
    for f in "${REQUIRED_BACKEND_FILES[@]}"; do
        [[ -f "$APP_SUPPORT/lib/backends/$f" ]] || { print -u2 -- "  ❌ lib/backends/$f missing at destination"; missing+=1; }
    done
    (( missing == 0 )) || { print -u2 -- "  → $missing lib file(s) missing — daemon functionality limited"; return 1; }

    print "OK — daemon PID $pid, state: $(/bin/cat "$APP_SUPPORT/state"), lib inventory complete ($((${#REQUIRED_LIB_FILES[@]} + ${#REQUIRED_BACKEND_FILES[@]})) files)."
}

# phase_applauncher — create a double-clickable launcher in the Applications
# folder that opens the TUI in Terminal.app. NON-FATAL: a failure here never
# aborts the install (the CLI + daemon work without it). The target dir is
# overridable via ATM_APP_DIR (tests); falls back to ~/Applications when the
# system /Applications is not writable.
phase_applauncher() {
    local app_name="Adobe Toggle.app"
    local app_base="${ATM_APP_DIR:-/Applications}"
    if [[ ! -d "$app_base" || ! -w "$app_base" ]]; then
        app_base="$HOME/Applications"
        /bin/mkdir -p "$app_base" 2>/dev/null
    fi
    local app_dir="$app_base/$app_name"
    if [[ ! -x /usr/bin/osacompile ]]; then
        print -u2 -- "  ⚠ osacompile not found — app launcher skipped (use the CLI: $CORE_DST)"
        return 0
    fi
    # AppleScript: open a Terminal window and run the deployed TUI. NOT via exec —
    # exec replaces the login shell, which breaks Terminal's `busy` tracking (an
    # auto-close then fired before the TUI was even visible). Plain `do script`
    # runs the TUI as a shell child; when you quit (q) the shell returns to a
    # usable prompt in that window (no dead "[Process completed]"). Auto-closing
    # the window is intentionally NOT done — Terminal's tab→window automation is
    # unreliable; a usable window is the robust behaviour. Single-quote the path
    # so the space in "Application Support" is safe in the shell command.
    local script="tell application \"Terminal\"
    activate
    do script \"clear; '${CORE_DST}'\"
end tell"
    /bin/rm -rf "$app_dir" 2>/dev/null
    if ! print -r -- "$script" | /usr/bin/osacompile -o "$app_dir" 2>/dev/null; then
        print -u2 -- "  ⚠ Could not create app launcher at $app_dir (non-fatal; use the CLI: $CORE_DST)"
        return 0
    fi
    # Optional custom icon: place a .icns at assets/adobe-toggle.icns in the repo
    # (or set ATM_APP_ICON). osacompile names the icon resource applet.icns and
    # sets Info.plist CFBundleIconFile=applet, so overwriting it applies the icon.
    local icon="${ATM_APP_ICON:-$SRC_DIR/assets/adobe-toggle.icns}"
    if [[ -f "$icon" ]]; then
        /bin/cp -f "$icon" "$app_dir/Contents/Resources/applet.icns" 2>/dev/null
        /usr/bin/touch "$app_dir" 2>/dev/null   # nudge the Finder icon cache
        print "  ✓ App launcher: $app_dir (custom icon)"
    else
        print "  ✓ App launcher: $app_dir"
    fi
    return 0
}

rollback() {
    local p
    print -u2 -- "Rollback…"
    # In reverse order
    for p in ${(@aO)_PHASES_DONE}; do
        case "$p" in
            bootstrap)
                /bin/launchctl bootout "gui/${UID}/${LABEL}" 2>/dev/null || true
                /bin/launchctl bootout "gui/${UID}/${HEALTHCHECK_LABEL}" 2>/dev/null || true
                ;;
            plist)
                /bin/rm -f "$PLIST_PATH"
                /bin/rm -f "$HEALTHCHECK_PLIST_PATH"
                ;;
            copy_scripts) /bin/rm -f "$CORE_DST" ;;
            appsupport) ;; # do not delete — logs/state could be valuable on a later install
        esac
    done
}

main() {
    print "Adobe Toggle Installer (v$APP_VERSION)"
    print "Source:        $CORE_SRC"
    print "App-Support:   $APP_SUPPORT"
    print "LaunchAgent:   $PLIST_PATH"
    print "Initial State: ${ATM_INITIAL_STATE:-block}"
    print

    [[ -f "$CORE_SRC" ]] || { print -u2 -- "Core script not found: $CORE_SRC"; return 2; }

    local phase
    for phase in preflight appsupport copy_scripts plist bootstrap verify applauncher; do
        print "→ Phase: $phase"
        if ! "phase_${phase}"; then
            print -u2 -- "Phase '$phase' failed."
            rollback
            return 1
        fi
    done
    print
    print "✅ Installation successful."
    print "   Show status / toggle: $CORE_DST"
}

main "$@"
