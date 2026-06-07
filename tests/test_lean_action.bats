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
    "
    # single combined final assertion — bats only checks the LAST command
    [[ "$output" == *"BLOAT_BLOCKED"* && "$output" == *"ESSENTIAL_KEPT"* ]]
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
        # not converted) AND is not blocked again.
        grep -c 'com.adobe.CCXProcess' \"\$ATM_DISABLED_FILE\"
    "
    # exactly one entry, still present (user intent persistent)
    [ "$output" = "1" ]
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
