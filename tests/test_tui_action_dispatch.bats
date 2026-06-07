#!/usr/bin/env bats
# PD-02 (v4.16.0): tests for the extracted _tui_action_* functions.
# Previously these code blocks were inline in the case switch of tui_menu_loop (120 LOC).

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISCOVERED_FILE="$ATM_BASE/discovered.list"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
}
teardown() { sandbox_teardown; }

# === Action functions exist with correct naming ==============================

@test "PD-02: all 7 _tui_action_<key> functions exist (a/b/d/s/u/w/l)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        for k in a b d s u w l; do
            if (( \${+functions[_tui_action_\$k]} )); then
                echo \"\$k: ok\"
            else
                echo \"\$k: MISSING\"
            fi
        done
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"a: ok"* ]]
    [[ "$output" == *"b: ok"* ]]
    [[ "$output" == *"d: ok"* ]]
    [[ "$output" == *"s: ok"* ]]
    [[ "$output" == *"u: ok"* ]]
    [[ "$output" == *"w: ok"* ]]
    [[ "$output" == *"l: ok"* ]]
}

# === _tui_action_a / _tui_action_b — state-write ==============================

@test "PD-02: _tui_action_a writes state=allow" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Stub render functions so no TTY output interferes
        _render_with_blink() { :; }
        _tui_signal_daemon() { return 1; }   # no daemon
        _auto_sudo_sweep_enabled() { return 1; }   # isolate state-write from v4.20.0 auto-chain
        _tui_action_a 2>/dev/null
        /bin/cat \"\$ATM_STATE_FILE\"
    "
    [[ "$output" == "allow" ]]
}

@test "PD-02: _tui_action_b writes state=block" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _render_with_blink() { :; }
        _tui_signal_daemon() { return 1; }
        _auto_sudo_sweep_enabled() { return 1; }   # isolate state-write from v4.20.0 auto-chain
        _tui_action_b 2>/dev/null
        /bin/cat \"\$ATM_STATE_FILE\"
    "
    [[ "$output" == "block" ]]
}

@test "lean (v1.1.0): _tui_action_l writes state=lean" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _render_with_blink() { :; }
        _tui_signal_daemon() { return 1; }
        _auto_sudo_sweep_enabled() { return 1; }
        _tui_action_l 2>/dev/null
        /bin/cat \"\$ATM_STATE_FILE\"
    "
    [[ "$output" == "lean" ]]
}

@test "lean (v1.1.0): _tui_action_l surfaces a re-enable hint when an essential system daemon is stuck" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        _render_with_blink() { echo \"RENDER:\$1\"; }
        _tui_signal_daemon() { return 1; }
        _auto_sudo_sweep_enabled() { return 1; }
        disabled_list_set_state com.adobe.SomeSystemEssential system auto_blocked
        _tui_action_l
    "
    [[ "$output" == *"[e]"* ]]
}

@test "lean (v1.1.0): _tui_action_l does NOT surface the hint when only bloat system daemons are off" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        _render_with_blink() { echo \"RENDER:\$1\"; }
        _tui_signal_daemon() { return 1; }
        _auto_sudo_sweep_enabled() { return 1; }
        disabled_list_set_state com.adobe.ARMDC.armdcHelper system auto_blocked
        _tui_action_l
    "
    [[ "$output" != *"[e]"* ]]
}

@test "lean (v1.1.0): status box shows a lean breakdown line in lean" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        write_state lean
        disabled_list_set_state com.adobe.CCXProcess gui auto_blocked
        _status_lines_for_box 60
    "
    [[ "$output" == *"Lean:"* && "$output" == *"bloat off"* ]]
}

@test "lean (v1.1.0): status box has NO lean breakdown line in allow" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        write_state allow
        _status_lines_for_box 60
    "
    [[ "$output" != *"Lean:"* ]]
}

# === _tui_action_d — discovery ================================================

@test "PD-02: _tui_action_d calls discovery_sweep + shows component count" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Stub discovery_sweep to write without an Adobe system
        discovery_sweep() {
            printf 'launchd\\tcom.adobe.A\\t/p1\\tgui\\n' > \"\$ATM_DISCOVERED_FILE\"
            printf 'launchd\\tcom.adobe.B\\t/p2\\tgui\\n' >> \"\$ATM_DISCOVERED_FILE\"
        }
        # Capture render-output
        _render_with_blink() { echo \"BLINK: \$1\"; }
        _tui_action_d 2>/dev/null
    "
    [[ "$output" == *"BLINK: Discovery: 2 components"* ]]
}

# === Dispatch logic in tui_menu_loop =========================================

@test "PD-02: function-lookup pattern prevents injection (e.g. choice='\$()')" {
    # If choice were "$(rm -rf /)", that must not be executed.
    # Verify: only [a-z] are accepted as an action key.
    run zsh -c '
        source '"'$SCRIPT'"' >/dev/null 2>&1
        choice="\$(echo PWNED)"
        # Reproduce the dispatch pattern from tui_menu_loop
        if [[ "$choice" =~ ^[a-z]$ ]] && (( ${+functions[_tui_action_${choice}]} )); then
            echo "DANGEROUS: would call _tui_action_${choice}"
        else
            echo "SAFE: rejected"
        fi
    '
    [[ "$output" == *"SAFE: rejected"* ]]
}

@test "PD-02: function lookup accepts only existing _tui_action_*" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        choice='z'   # there is no _tui_action_z
        if [[ \"\$choice\" =~ ^[a-z]$ ]] && (( \${+functions[_tui_action_\${choice}]} )); then
            echo 'WOULD CALL z'
        else
            echo 'rejected (z missing)'
        fi
    "
    [[ "$output" == *"rejected (z missing)"* ]]
}

# === Helper functions ========================================================

@test "PD-02: _tui_full_render exists and is callable" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Stub all the TUI render functions
        tui_render_status() { :; }
        _tui_render_menu_hint() { :; }
        _render_right_border_full() { :; }
        # Should run through without error (clear is in PATH)
        _tui_full_render 1 2>/dev/null >/dev/null
        echo \"exit=\$?\"
    "
    [[ "$output" == *"exit=0"* ]]
}

@test "PD-02: _tui_read_key_with_animation exists" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        if (( \${+functions[_tui_read_key_with_animation]} )); then
            echo ok
        fi
    "
    [[ "$output" == "ok" ]]
}
