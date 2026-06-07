#!/usr/bin/env bats
# v4.19.0: Tests for sudo_unsweep_action (the allow counterpart to sudo_sweep_action).
# Testable paths are all PRE-sudo: empty disabled.list, only user_allowed,
# only gui|user-scope, missing Touch ID. The happy path with real sudo is NOT
# automatable until the ATM_SUDO_BIN hook is introduced (TODO Phase 3 — the same
# gap also affects sudo_sweep_action; see pam.zsh).

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# Helper: minimal state setup so the function is sourceable
_init_state() {
    mkdir -p "$ATM_BASE/logs"
    printf 'allow\n' > "$ATM_BASE/state"
}

@test "sudo_unsweep_action: empty disabled.list → return 0, no-op" {
    _init_state
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; sudo_unsweep_action"
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled.list is empty"* ]]
}

@test "sudo_unsweep_action: disabled.list with only user_allowed → return 0, no sudo call" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.user.flag	system	2026-05-07T08:00:00Z	user_allowed
EOF
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; sudo_unsweep_action"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No system-scope entries"* ]]
}

@test "sudo_unsweep_action: disabled.list with only gui|user-scope → return 0 (system-only filter)" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.userland	user	2026-05-07T08:00:00Z	auto_blocked
com.adobe.guiland	gui	2026-05-07T08:00:00Z	user_blocked
EOF
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; sudo_unsweep_action"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No system-scope entries"* ]]
}

@test "sudo_unsweep_action: system entries without Touch ID → return 1, prints hint" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
Adobe_Genuine_Software_Integrity_Service	system	2026-05-07T08:27:25Z	auto_blocked
com.adobe.ARMDC.Communicator	system	2026-05-07T08:27:25Z	auto_blocked
EOF
    pam_tid_disable
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; sudo_unsweep_action"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Touch ID"* ]]
    [[ "$output" == *"sudo_local"* ]]
    # disabled.list stays unchanged (no sudo, no enable)
    grep -q "Adobe_Genuine_Software_Integrity_Service" "$ATM_BASE/disabled.list"
    grep -q "com.adobe.ARMDC.Communicator" "$ATM_BASE/disabled.list"
}

@test "sudo_unsweep_action: system + user_allowed mixed — user_allowed is skipped" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.system.auto	system	2026-05-07T08:27:25Z	auto_blocked
com.adobe.system.user_allow	system	2026-05-07T08:27:25Z	user_allowed
EOF
    pam_tid_disable
    # With an auto_blocked entry: the Touch ID check kicks in → return 1 (no sudo).
    # Important: user_allowed does NOT appear in the list that gets enabled.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; sudo_unsweep_action"
    [ "$status" -eq 1 ]
    [[ "$output" == *"com.adobe.system.auto"* ]]
    [[ "$output" != *"com.adobe.system.user_allow"* ]]
}

@test "_tui_action_e: function exists + is callable after script source" {
    _init_state
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; (( \${+functions[_tui_action_e]} )) && echo defined"
    [ "$status" -eq 0 ]
    [[ "$output" == *"defined"* ]]
}

@test "Menu hint contains [e] Sudo-Unsweep" {
    _init_state
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _tui_render_menu_hint"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[e]"* ]]
    [[ "$output" == *"Sudo-Unsweep"* ]]
}

# v4.19.0 PHANTOM-FIX: allow_action must NOT drop scope=system,
# otherwise sudo_unsweep_action can no longer find them.
@test "PHANTOM-FIX: allow_action keeps scope=system in disabled.list" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.system.foo	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.system.bar	system	2026-05-07T08:00:00Z	user_blocked
com.adobe.user.baz	user	2026-05-07T08:00:00Z	auto_blocked
com.adobe.gui.qux	gui	2026-05-07T08:00:00Z	auto_blocked
EOF
    # Run allow_action — indirectly depends on enable_launchd_label
    # for gui|user; the system path is a no-op without sudo, but should keep the entry.
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; allow_action 2>/dev/null; cat '$ATM_BASE/disabled.list'"
    [ "$status" -eq 0 ]
    # 2 system entries MUST remain (auto_blocked + user_blocked)
    [[ "$output" == *"com.adobe.system.foo"* ]]
    [[ "$output" == *"com.adobe.system.bar"* ]]
    # gui/user entries are dropped (no launchctl mock hit is OK,
    # because enable_launchd_label does not write the tmp file itself)
    [[ "$output" != *"com.adobe.user.baz"* ]]
    [[ "$output" != *"com.adobe.gui.qux"* ]]
}

@test "PHANTOM-FIX: allow_action still keeps user_allowed system entries" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.system.user_allow	system	2026-05-07T08:00:00Z	user_allowed
EOF
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; allow_action 2>/dev/null; cat '$ATM_BASE/disabled.list'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.system.user_allow"* ]]
    [[ "$output" == *"user_allowed"* ]]
}

# v4.19.0 (C): pending counter is set + WARN_NEEDS_SUDO logged exactly 1×
# (LOG-1 lesson: no per-item spam).
@test "(C) allow_action sets _DAEMON_PENDING_SYSTEM = number of system items" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.sys.a	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.sys.b	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.sys.c	system	2026-05-07T08:00:00Z	user_blocked
com.adobe.user.x	user	2026-05-07T08:00:00Z	auto_blocked
com.adobe.sys.allowed	system	2026-05-07T08:00:00Z	user_allowed
EOF
    # _DAEMON_PENDING_SYSTEM must = 3 (3 system entries without user_allowed)
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; allow_action 2>/dev/null; print -- \$_DAEMON_PENDING_SYSTEM"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3"* ]]
}

@test "(C) allow_action logs WARN_NEEDS_SUDO exactly 1× per run (not per item)" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.sys.a	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.sys.b	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.sys.c	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.sys.d	system	2026-05-07T08:00:00Z	auto_blocked
EOF
    # ATM_LOGS_DIR is set INSIDE the script via $ATM_BASE — the outer bash only knows ATM_BASE.
    # So build the path directly from ATM_BASE, not $ATM_LOGS_DIR from the outer shell.
    run zsh -c "setopt NULL_GLOB; source '$SCRIPT' >/dev/null 2>&1; allow_action 2>/dev/null; cat '$ATM_BASE/logs'/adobe-toggle.*.events.ndjson 2>/dev/null || true"
    [ "$status" -eq 0 ]
    # Exactly 1 WARN_NEEDS_SUDO with an aggregated count detail
    local warn_count=$(echo "$output" | grep -c '"event":"WARN_NEEDS_SUDO"')
    [ "$warn_count" -eq 1 ]
    [[ "$output" == *"allow_pending_system_count=4"* ]]
}

@test "(C) allow_action WITHOUT system entries → _DAEMON_PENDING_SYSTEM=0, no WARN log" {
    _init_state
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.user.x	user	2026-05-07T08:00:00Z	auto_blocked
EOF
    run zsh -c "setopt NULL_GLOB; source '$SCRIPT' >/dev/null 2>&1; allow_action 2>/dev/null; print -- \"PEND=\$_DAEMON_PENDING_SYSTEM\"; cat '$ATM_BASE/logs'/adobe-toggle.*.events.ndjson 2>/dev/null || true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PEND=0"* ]]
    # No WARN_NEEDS_SUDO entry expected
    [[ "$output" != *'"event":"WARN_NEEDS_SUDO"'* ]]
}

@test "(C) live_state_write mirrors _DAEMON_PENDING_SYSTEM into the live-state file" {
    _init_state
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _DAEMON_PENDING_SYSTEM=7; live_state_write; live_state_get pending_system"
    [ "$status" -eq 0 ]
    [[ "$output" == *"7"* ]]
}

# v4.19.1: live_state_set targeted update + sudo_unsweep_action counter reset
@test "(v4.19.1) live_state_set: existing key is updated in place" {
    _init_state
    mkdir -p "$ATM_BASE"
    printf 'heartbeat_ts=1000\nticks=42\npending_system=4\nkilled=7\n' > "$ATM_BASE/live_state"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; live_state_set pending_system 0; cat '$ATM_BASE/live_state'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending_system=0"* ]]
    # other fields stay unchanged
    [[ "$output" == *"heartbeat_ts=1000"* ]]
    [[ "$output" == *"ticks=42"* ]]
    [[ "$output" == *"killed=7"* ]]
    [[ "$output" != *"pending_system=4"* ]]
}

@test "(v4.19.1) live_state_set: missing key is appended" {
    _init_state
    mkdir -p "$ATM_BASE"
    printf 'heartbeat_ts=1000\nticks=42\n' > "$ATM_BASE/live_state"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; live_state_set new_field hello; cat '$ATM_BASE/live_state'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"new_field=hello"* ]]
    [[ "$output" == *"heartbeat_ts=1000"* ]]
    [[ "$output" == *"ticks=42"* ]]
}

@test "(v4.19.1) live_state_set overwrites NO other daemon counters" {
    _init_state
    mkdir -p "$ATM_BASE"
    # Realistic live_state with real daemon values
    printf 'heartbeat_ts=1778147996\nticks=15\ndisabled=4\nkilled=12\nlast_disable=11:23:45|com.adobe.x:gui\nlast_kill=\npending_system=4\n' > "$ATM_BASE/live_state"
    # TUI mode simulation: global daemon vars are 0 (no daemon tick ran in this shell)
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _DAEMON_TICKS=0; _DAEMON_KILLED=0; live_state_set pending_system 0; cat '$ATM_BASE/live_state'"
    [ "$status" -eq 0 ]
    # ticks/killed must NOT be set to 0 by live_state_set
    [[ "$output" == *"ticks=15"* ]]
    [[ "$output" == *"killed=12"* ]]
    [[ "$output" == *"pending_system=0"* ]]
}

@test "(v4.19.1) sudo_unsweep_action: no system items → pending stays 0" {
    _init_state
    mkdir -p "$ATM_BASE"
    printf 'pending_system=0\n' > "$ATM_BASE/live_state"
    : > "$ATM_BASE/disabled.list"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; sudo_unsweep_action 2>&1; live_state_get pending_system"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0"* ]]
}

# v4.19.2: the ATM_SUDO_BIN hook now enables happy-path tests with mocked sudo

@test "(v4.19.2) sudo_unsweep_action happy path: 2 system items are enabled + bootstrap" {
    _init_state
    pam_tid_enable sudo_local
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.test.system.a	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.test.system.b	system	2026-05-07T08:00:00Z	auto_blocked
EOF
    # Mock with a 'y' answer + sudo cred validation
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; print 'y' | sudo_unsweep_action 2>&1; print '---log---'; cat '$ATM_MOCK_LOG_DIR/sudo.log'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 System-LaunchDaemons enabled"* ]]
    # sudo was actually called — sudo -v + 2× enable
    local sudo_calls=$(grep -c '^' "$ATM_MOCK_LOG_DIR/sudo.log")
    [ "$sudo_calls" -ge 3 ]
    # disabled.list is empty after success (system entries removed)
    local remaining=$(awk -F'\t' '$2=="system" && $4!="user_allowed" {n++} END{print n+0}' "$ATM_BASE/disabled.list")
    [ "$remaining" -eq 0 ]
}

@test "(v4.19.2) sudo_unsweep_action happy path: _DAEMON_PENDING_SYSTEM after success = 0" {
    _init_state
    pam_tid_enable sudo_local
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.test.system.a	system	2026-05-07T08:00:00Z	auto_blocked
EOF
    # Artificially set the pending counter to 1 beforehand
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _DAEMON_PENDING_SYSTEM=1; print 'y' | sudo_unsweep_action 2>&1; live_state_get pending_system"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0"* ]]
}

@test "(v4.19.2) sudo_unsweep_action: user_allowed is NOT enabled, stays in disabled.list" {
    _init_state
    pam_tid_enable sudo_local
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.test.system.auto	system	2026-05-07T08:00:00Z	auto_blocked
com.adobe.test.system.user_allow	system	2026-05-07T08:00:00Z	user_allowed
EOF
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; print 'y' | sudo_unsweep_action 2>&1; cat '$ATM_BASE/disabled.list'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 System-LaunchDaemons enabled"* ]]
    # auto_blocked → enabled + removed
    [[ "$output" != *"com.adobe.test.system.auto"$'\t'"system"* ]] || true
    # user_allowed → stays
    [[ "$output" == *"com.adobe.test.system.user_allow"* ]]
    [[ "$output" == *"user_allowed"* ]]
}

@test "(v4.19.2) sudo_unsweep_action: user cancel via 'n' → no sudo call" {
    _init_state
    pam_tid_enable sudo_local
    cat > "$ATM_BASE/disabled.list" <<EOF
com.adobe.test.system.a	system	2026-05-07T08:00:00Z	auto_blocked
EOF
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; print 'n' | sudo_unsweep_action 2>&1; print '---log---'; cat '$ATM_MOCK_LOG_DIR/sudo.log' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aborted"* ]]
    # No sudo was called (log is empty)
    local sudo_calls=$(wc -l < "$ATM_MOCK_LOG_DIR/sudo.log" | tr -d ' ')
    [ "$sudo_calls" -eq 0 ]
}

@test "(v4.19.2) ATM_SUDO_REAL_DENY=1 + Adobe label → _sudo refused (defense-in-depth)" {
    # Hard-guard test: REAL_DENY is set in sandbox_setup, but ATM_SUDO_BIN
    # points at mock_sudo. For this test we set ATM_SUDO_BIN to
    # /usr/bin/sudo (= real sudo) — the guard MUST then fire.
    _init_state
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; ATM_SUDO_BIN=/usr/bin/sudo ATM_SUDO_REAL_DENY=1 _sudo /bin/launchctl enable system/com.adobe.test 2>&1"
    [ "$status" -eq 99 ]
    [[ "$output" == *"refusing real sudo"* ]]
}

@test "(C) TUI status line appears only when pending > 0" {
    _init_state
    # No pending → no pending line
    mkdir -p "$ATM_BASE"
    printf 'pending_system=0\n' > "$ATM_BASE/live_state"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _status_lines_for_box 56"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Pending:"* ]]

    # With pending → pending line present
    printf 'pending_system=4\n' > "$ATM_BASE/live_state"
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _status_lines_for_box 56"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pending:"* ]]
    [[ "$output" == *"4 system-Items"* ]]
    [[ "$output" == *"[e]"* ]]
}
