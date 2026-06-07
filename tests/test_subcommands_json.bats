#!/usr/bin/env bats
# End-to-end tests for status / discovery / summary subcommands with --json.
# Uses sandbox mocks for launchctl etc., manipulates ATM_BASE files directly.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    # Ensure ATM_BASE has the required runtime layout for json_emit_*
    /bin/mkdir -p "$ATM_BASE"
    echo "block" > "$ATM_BASE/state"
}
teardown() { sandbox_teardown; }

# Run the full script with sandbox-overrides, capture stdout.
_run_script() {
    /bin/zsh -c "
        export ATM_BASE='$ATM_BASE'
        export ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
        export ATM_CODESIGN_BIN='$ATM_CODESIGN_BIN'
        export ATM_LAUNCHCTL_REAL_DENY=1
        '$SCRIPT' $*
    "
}

@test "status (text): prints state + pid line" {
    run _run_script "status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"state=block"* ]]
    [[ "$output" == *"healthy="* ]]
}

@test "status --json: produces valid JSON" {
    run _run_script "status --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -m json.tool > /dev/null
}

@test "status --json: state=block reflected" {
    run _run_script "status --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['state'] == 'block'
"
}

@test "status --json: state=allow when state file changed" {
    echo "allow" > "$ATM_BASE/state"
    run _run_script "status --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['state'] == 'allow'
"
}

@test "lean (v1.1.0): status --json reflects state=lean (passthrough)" {
    echo "lean" > "$ATM_BASE/state"
    run _run_script "status --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['state'] == 'lean', d['state']
"
}

@test "status --json: healthy=false in sandbox (no live daemon)" {
    # The sandbox mock launchctl returns pid=12345 (default stub output).
    # That PID does not exist in the test process tree → kill -0 fails.
    # Expected: healthy=false with reason 'no-pid' OR 'pid-not-alive'.
    run _run_script "status --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['daemon']['healthy'] == False
assert d['daemon']['healthy_reason'] in ('no-pid', 'pid-not-alive')
"
}

@test "discovery (text): dumps discovered.list when populated" {
    printf 'launchd\tcom.adobe.test\t/path/to/test.plist\tgui\n' > "$ATM_BASE/discovered.list"
    run _run_script "discovery"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.adobe.test"* ]]
}

@test "discovery --json: parses populated discovered.list" {
    printf 'launchd\tcom.adobe.test\t/path/to/test.plist\tgui\n' > "$ATM_BASE/discovered.list"
    printf 'pluginkit\tcom.adobe.ext\t/path/to/ext.appex\tuser\n' >> "$ATM_BASE/discovered.list"
    run _run_script "discovery --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert len(d['discovered']) == 2
assert d['discovered'][0]['backend'] == 'launchd'
assert d['discovered'][0]['label'] == 'com.adobe.test'
assert d['discovered'][1]['backend'] == 'pluginkit'
"
}

@test "discovery --json: empty discovered.list → empty array" {
    run _run_script "discovery --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['discovered'] == []
"
}

@test "summary --json: counts disabled + discovered" {
    printf 'launchd\tcom.adobe.a\t/p/a.plist\tgui\n' > "$ATM_BASE/discovered.list"
    printf 'launchd\tcom.adobe.b\t/p/b.plist\tgui\n' >> "$ATM_BASE/discovered.list"
    printf 'com.adobe.x\tgui\t2026-05-03T12:00:00Z\n' > "$ATM_BASE/disabled.list"
    run _run_script "summary --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['discovered_count'] == 2
assert d['disabled_count'] == 1
assert d['disabled'][0]['label'] == 'com.adobe.x'
assert d['disabled'][0]['scope'] == 'gui'
"
}

@test "--summary alias still works (backward-compat)" {
    run _run_script "--summary"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Live State"* || "$output" == *"Disabled Labels"* ]]
}

@test "--summary --json works (alias forwards args)" {
    run _run_script "--summary --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -m json.tool > /dev/null
}

@test "json-output has no trailing whitespace before newline (single-line compact)" {
    run _run_script "status --json"
    [ "$status" -eq 0 ]
    # Must be one logical line (compact). Count newlines: should be exactly 1 (terminal).
    local nl_count
    nl_count=$(printf '%s' "$output" | /usr/bin/awk 'END{print NR}')
    [ "$nl_count" -eq 1 ]
}

@test "label is correctly escaped (no raw-quotes)" {
    run _run_script "status --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['label'] == 'com.user.adobe-toggle.daemon'
"
}

@test "discovery TSV with trailing empty fields parses correctly" {
    # Edge case: scope might be empty for some backends.
    printf 'launchd\tcom.adobe.weird\t/p/weird.plist\t\n' > "$ATM_BASE/discovered.list"
    run _run_script "discovery --json"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['discovered'][0]['scope'] == ''
"
}
