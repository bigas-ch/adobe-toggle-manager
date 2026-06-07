#!/usr/bin/env bats
# PD-01 (v4.16.0): Tests for the extracted daemon helper functions.
# Previously these code blocks were inline in daemon_main (117 LOC),
# now individually callable + testable.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
}
teardown() { sandbox_teardown; }

# === _daemon_resolve_interval =================================================

@test "PD-01: _daemon_resolve_interval with watcher → safety-tick-interval" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=1
        config_set safety-tick-interval 200 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "200" ]]
}

@test "PD-01: _daemon_resolve_interval without watcher → tick-interval" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=0
        config_set tick-interval 45 >/dev/null 2>&1
        _daemon_resolve_interval
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "45" ]]
}

@test "PD-01: _daemon_resolve_interval with non-numeric config → fallback default" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=0
        # Configure a non-numeric value (manually in the config file)
        echo 'tick-interval=abc' > \$ATM_CONFIG_FILE
        _daemon_resolve_interval
    "
    [ "$status" -eq 0 ]
    # Default is DEFAULT_TICK_INTERVAL (30 in the constants)
    [[ "$output" == "30" ]]
}

@test "PD-01: _daemon_resolve_interval without config → default" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_WATCHER_ACTIVE=0
        # No config file
        [[ ! -f \$ATM_CONFIG_FILE ]] && _daemon_resolve_interval
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "30" ]]
}

# === _daemon_run_action ========================================================

@test "PD-01: _daemon_run_action 'block' calls discovery_sweep + block_action" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        # Stub the functions
        typeset -gi _called_sweep=0 _called_block=0
        discovery_sweep() { _called_sweep=1; }
        block_action() { _called_block=1; }
        _daemon_run_action block
        echo \"sweep=\$_called_sweep block=\$_called_block\"
    "
    [[ "$output" == *"sweep=1"* ]]
    [[ "$output" == *"block=1"* ]]
}

@test "PD-01: _daemon_run_action 'allow' calls only allow_action" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _called_sweep=0 _called_allow=0
        discovery_sweep() { _called_sweep=1; }
        allow_action() { _called_allow=1; }
        _daemon_run_action allow
        echo \"sweep=\$_called_sweep allow=\$_called_allow\"
    "
    [[ "$output" == *"sweep=0"* ]]
    [[ "$output" == *"allow=1"* ]]
}

@test "PD-01: _daemon_run_action with unknown state logs a warning" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        _daemon_run_action banana
        /bin/cat \"\$ATM_LOGS_DIR/adobe-toggle.\$(/bin/date +%Y-%m-%d).ndjson\" 2>/dev/null
    "
    [[ "$output" == *"unknown state"* ]]
    [[ "$output" == *"banana"* ]]
}

@test "lean (v1.1.0): _daemon_run_action 'lean' calls discovery_sweep + lean_action only" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _called_sweep=0 _called_lean=0 _called_block=0 _called_allow=0
        discovery_sweep() { _called_sweep=1; }
        lean_action()  { _called_lean=1; }
        block_action() { _called_block=1; }
        allow_action() { _called_allow=1; }
        _daemon_run_action lean
        echo \"sweep=\$_called_sweep lean=\$_called_lean block=\$_called_block allow=\$_called_allow\"
    "
    # combined final assertion (bats only checks the LAST command)
    [[ "$output" == *"sweep=1"* && "$output" == *"lean=1"* && "$output" == *"block=0"* && "$output" == *"allow=0"* ]]
}

# === _daemon_periodic_maintenance =============================================

@test "PD-01: _daemon_periodic_maintenance calls cache_save at tick%10==0" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_TICKS=10
        typeset -gi _called_save=0
        _authority_cache_save() { _called_save=1; }
        _daemon_periodic_maintenance
        echo \"save=\$_called_save\"
    "
    [[ "$output" == *"save=1"* ]]
}

@test "PD-01: _daemon_periodic_maintenance skips cache_save at tick%10!=0" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_TICKS=7
        typeset -gi _called_save=0
        _authority_cache_save() { _called_save=1; }
        _daemon_periodic_maintenance
        echo \"save=\$_called_save\"
    "
    [[ "$output" == *"save=0"* ]]
}

@test "PD-01: _daemon_periodic_maintenance calls log_cleanup at tick%120==0" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_TICKS=120
        typeset -gi _called_cleanup=0
        log_cleanup() { _called_cleanup=1; }
        _daemon_periodic_maintenance
        echo \"cleanup=\$_called_cleanup\"
    "
    [[ "$output" == *"cleanup=1"* ]]
}

# === _daemon_interruptible_sleep ==============================================

# bats test_tags=perf
@test "PD-01: _daemon_interruptible_sleep skips when TICK_NOW=1" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_RUNNING=1
        typeset -gi _DAEMON_TICK_NOW=1
        typeset -gi _DAEMON_SLEEP_PID=0
        local t1=\$(/bin/date +%s%N)
        _daemon_interruptible_sleep 5
        local t2=\$(/bin/date +%s%N)
        local elapsed=\$(( (t2 - t1) / 1000000 ))
        echo \"elapsed=\${elapsed}ms tick_now=\${_DAEMON_TICK_NOW}\"
    "
    [[ "$output" == *"tick_now=0"* ]]
    # Should be very fast (skip)
    [[ "$output" =~ elapsed=([0-9]+)ms ]]
    local ms="${BASH_REMATCH[1]}"
    [ "$ms" -lt 200 ]
}

# bats test_tags=perf
@test "PD-01: _daemon_interruptible_sleep skips when RUNNING=0" {
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        typeset -gi _DAEMON_RUNNING=0
        typeset -gi _DAEMON_TICK_NOW=0
        typeset -gi _DAEMON_SLEEP_PID=0
        local t1=\$(/bin/date +%s%N)
        _daemon_interruptible_sleep 5
        local t2=\$(/bin/date +%s%N)
        echo \"elapsed=\$(( (t2 - t1) / 1000000 ))ms\"
    "
    [[ "$output" =~ elapsed=([0-9]+)ms ]]
    local ms="${BASH_REMATCH[1]}"
    [ "$ms" -lt 200 ]
}
