#!/usr/bin/env bats
# Lean-state (v1.1.0): lean_action disables only curated bloat, keeps
# essentials, and cleanly downgrades a prior `block` (re-enables non-bloat).
# Plus the kill predicate _lean_kill_is_bloat used to spare essential
# processes from the kill loop.

load helpers/sandbox.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "lean_action disables bloat launchd label, keeps essential" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        printf 'launchd\tcom.adobe.CCXProcess\t/p1\tgui\n' >  \"\$ATM_DISCOVERED_FILE\"
        printf 'launchd\tcom.adobe.AcrobatLicensing\t/p2\tgui\n' >> \"\$ATM_DISCOVERED_FILE\"
        lean_action
        grep -q 'com.adobe.CCXProcess' \"\$ATM_DISABLED_FILE\" && echo BLOAT_BLOCKED
        grep -q 'com.adobe.AcrobatLicensing' \"\$ATM_DISABLED_FILE\" && echo ESSENTIAL_BLOCKED || echo ESSENTIAL_KEPT
        # Phase-1 behaviour, independent of phase-2 disabled.list normalisation:
        # the essential must receive ZERO launchctl calls; the bloat must be acted on.
        grep -q 'com.adobe.AcrobatLicensing' \"\$ATM_MOCK_LOG_DIR/launchctl.log\" && echo ESSENTIAL_TOUCHED || echo ESSENTIAL_UNTOUCHED
        grep -q 'com.adobe.CCXProcess' \"\$ATM_MOCK_LOG_DIR/launchctl.log\" && echo BLOAT_TOUCHED || echo BLOAT_UNTOUCHED
    "
    # combined final assertion (bats only checks the LAST command). The mock-log
    # asserts pin phase 1 so a removed _is_lean_blocked gate can't hide behind the
    # phase-2 re-enable (which would make the essential get bootout/disable/enable
    # churn while still looking clean in disabled.list).
    [[ "$output" == *"BLOAT_BLOCKED"* && "$output" == *"ESSENTIAL_KEPT"* \
       && "$output" == *"ESSENTIAL_UNTOUCHED"* && "$output" == *"BLOAT_TOUCHED"* ]]
}

@test "lean_action re-enables a non-bloat label a prior block had disabled" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        printf 'launchd\tcom.adobe.CCXProcess\t/p1\tgui\n' >  \"\$ATM_DISCOVERED_FILE\"
        printf 'launchd\tcom.adobe.AcrobatLicensing\t/p2\tgui\n' >> \"\$ATM_DISCOVERED_FILE\"
        # simulate a prior global block: BOTH disabled
        disabled_list_set_state com.adobe.CCXProcess gui auto_blocked
        disabled_list_set_state com.adobe.AcrobatLicensing gui auto_blocked
        lean_action
        grep -q 'com.adobe.AcrobatLicensing' \"\$ATM_DISABLED_FILE\" && echo STILL_BLOCKED || echo RE_ENABLED
        grep -q 'com.adobe.CCXProcess' \"\$ATM_DISABLED_FILE\" && echo BLOAT_STAYS || echo BLOAT_GONE
    "
    [[ "$output" == *"RE_ENABLED"* && "$output" == *"BLOAT_STAYS"* ]]
}

@test "lean_action keeps a user_allowed bloat label running" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        printf 'launchd\tcom.adobe.CCXProcess\t/p1\tgui\n' > \"\$ATM_DISCOVERED_FILE\"
        disabled_list_set_state com.adobe.CCXProcess gui user_allowed
        lean_action
        # user_allowed entry stays in disabled.list as user_allowed (not enabled,
        # not converted to auto_blocked). Pin BOTH: exactly one entry AND the
        # state column is still user_allowed (a line-count-only check would miss
        # a user_allowed→auto_blocked corruption that allow_action later wipes).
        echo \"count=\$(grep -c 'com.adobe.CCXProcess' \"\$ATM_DISABLED_FILE\")\"
        echo \"state=\$(disabled_list_get_state com.adobe.CCXProcess)\"
    "
    [[ "$output" == *"count=1"* && "$output" == *"state=user_allowed"* ]]
}

@test "lean kill predicate: bloat process → kill (return 0)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _lean_kill_is_bloat 'com.adobe.CCXProcess' '/x' && echo KILL || echo SPARE"
    [ "$output" = "KILL" ]
}

@test "lean kill predicate: essential process → spare (return non-0)" {
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; init_state; _lean_kill_is_bloat 'com.adobe.Photoshop' '/Applications/Adobe Photoshop/Adobe Photoshop.app' && echo KILL || echo SPARE"
    [ "$output" = "SPARE" ]
}

@test "lean kill predicate: user_allowed bloat → spare" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        disabled_list_set_state com.adobe.CCXProcess gui user_allowed 2>/dev/null
        _lean_kill_is_bloat 'com.adobe.CCXProcess' '/x' && echo KILL || echo SPARE
    "
    [ "$output" = "SPARE" ]
}

@test "lean kill predicate: non-bloat + user_blocked → kill (spec 3.3 parity with launchd path)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        disabled_list_set_state com.adobe.SomeEssential gui user_blocked 2>/dev/null
        _lean_kill_is_bloat 'com.adobe.SomeEssential' '/x' && echo KILL || echo SPARE
    "
    [ "$output" = "KILL" ]
}

@test "lean pending: a non-bloat system entry left disabled counts as pending essential" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        disabled_list_set_state com.adobe.SomeSystemEssential system auto_blocked
        _lean_pending_essential_system_count
    "
    [ "$output" = "1" ]
}

@test "lean pending: a bloat system entry left disabled is NOT counted (correctly stays off)" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        disabled_list_set_state com.adobe.ARMDC.armdcHelper system auto_blocked
        _lean_pending_essential_system_count
    "
    [ "$output" = "0" ]
}

@test "lean pending: a user_allowed system entry is NOT counted" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        disabled_list_set_state com.adobe.SomeSystemEssential system user_allowed
        _lean_pending_essential_system_count
    "
    [ "$output" = "0" ]
}

@test "lean_action keeps a system-scope entry in disabled.list (user-mode cannot re-enable system)" {
    # A non-bloat system entry a prior block disabled would normally be re-enabled
    # in step 2 — but system scope is kept (the user-mode daemon cannot enable it
    # without sudo). Pins the system branch of the re-enable pass.
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1; init_state
        printf 'launchd\tcom.adobe.SomeSystemDaemon\t/p1\tsystem\n' > \"\$ATM_DISCOVERED_FILE\"
        disabled_list_set_state com.adobe.SomeSystemDaemon system auto_blocked
        lean_action
        grep -q 'com.adobe.SomeSystemDaemon' \"\$ATM_DISABLED_FILE\" && echo SYSTEM_KEPT || echo SYSTEM_DROPPED
    "
    [ "$output" = "SYSTEM_KEPT" ]
}
