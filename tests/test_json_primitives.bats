#!/usr/bin/env bats
# Unit tests for lib/json.zsh primitives (json_str, json_num, json_bool, json_null).
# Validation via /usr/bin/python3 -m json.tool to confirm RFC-8259-conformance.

load helpers/sandbox.bash

setup() {
    sandbox_setup
}
teardown() { sandbox_teardown; }

# Source json.zsh in isolation. APP_VERSION etc. would normally come from
# adobe-toggle — we set the minimum globals the encoder reads.
_source_json() {
    /bin/zsh -c "
        emulate -L zsh
        setopt PIPE_FAIL
        typeset -g APP_VERSION='4.7.0-test'
        typeset -g APP_LABEL='com.test.label'
        typeset -g _BACKENDS_AVAILABLE=1
        typeset -g DEFAULT_TICK_INTERVAL=30
        typeset -g DEFAULT_SAFETY_TICK_INTERVAL=300
        # Minimal stubs for read_state / live_state_get / _launchctl
        function read_state() { print -- 'block'; }
        function live_state_get() { return 1; }
        function _launchctl() { return 1; }
        source '$BATS_TEST_DIRNAME/../lib/json.zsh'
        $1
    "
}

@test "json_str: simple ASCII roundtrips through python json.tool" {
    run _source_json 'json_str "hello world"'
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "import json,sys; assert json.loads(sys.stdin.read()) == 'hello world'"
}

@test "json_str: escapes double-quote" {
    run _source_json 'json_str "she said \"hi\""'
    [ "$status" -eq 0 ]
    [[ "$output" == '"she said \"hi\""' ]]
    echo "$output" | /usr/bin/python3 -c "import json,sys; assert json.loads(sys.stdin.read()) == 'she said \"hi\"'"
}

@test "json_str: escapes backslash" {
    run _source_json 'json_str "C:\\path"'
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "import json,sys; assert json.loads(sys.stdin.read()) == 'C:\\\\path'"
}

@test "json_str: escapes literal newline char to \\n" {
    # A real newline char (via $'\n') becomes the JSON escape \n.
    run _source_json $'json_str "line1\nline2"'
    [ "$status" -eq 0 ]
    [[ "$output" == '"line1\nline2"' ]]
    # Python roundtrip: json.loads → real newline char again
    echo "$output" | /usr/bin/python3 -c $'import json,sys; assert json.loads(sys.stdin.read()) == "line1\\nline2"'
}

@test "json_str: empty string" {
    run _source_json 'json_str ""'
    [ "$status" -eq 0 ]
    [[ "$output" == '""' ]]
}

@test "json_num: integer" {
    run _source_json 'json_num 42'
    [ "$status" -eq 0 ]
    [[ "$output" == "42" ]]
}

@test "json_num: negative integer" {
    run _source_json 'json_num -7'
    [ "$status" -eq 0 ]
    [[ "$output" == "-7" ]]
}

@test "json_num: decimal" {
    run _source_json 'json_num 3.14'
    [ "$status" -eq 0 ]
    [[ "$output" == "3.14" ]]
}

@test "json_num: non-numeric falls back to quoted string (defensive)" {
    run _source_json 'json_num "not a number"'
    [ "$status" -eq 0 ]
    [[ "$output" == '"not a number"' ]]
}

@test "json_bool: 1 → true" {
    run _source_json 'json_bool 1'
    [ "$status" -eq 0 ]
    [[ "$output" == "true" ]]
}

@test "json_bool: 0 → false" {
    run _source_json 'json_bool 0'
    [ "$status" -eq 0 ]
    [[ "$output" == "false" ]]
}

@test "json_bool: 'true' → true" {
    run _source_json 'json_bool true'
    [ "$status" -eq 0 ]
    [[ "$output" == "true" ]]
}

@test "json_null: emits null literal" {
    run _source_json 'json_null'
    [ "$status" -eq 0 ]
    [[ "$output" == "null" ]]
}

@test "json_emit_status: produces valid JSON parseable by python" {
    # mock empty live_state, no daemon → all defaults
    run _source_json 'json_emit_status'
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -m json.tool > /dev/null
}

@test "json_emit_status: contains required schema keys" {
    run _source_json 'json_emit_status'
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'version' in d
assert 'state' in d
assert 'daemon' in d
assert 'pid' in d['daemon']
assert 'ticks' in d['daemon']
assert 'healthy' in d['daemon']
assert 'healthy_reason' in d['daemon']
assert 'backends' in d
"
}

@test "json_emit_status: healthy=false when no daemon (no-pid)" {
    run _source_json 'json_emit_status'
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['daemon']['healthy'] == False
assert d['daemon']['healthy_reason'] == 'no-pid'
"
}

@test "json_emit_discovery: empty discovered.list → empty array" {
    run _source_json 'typeset -g ATM_DISCOVERED_FILE="/nonexistent"; json_emit_discovery'
    [ "$status" -eq 0 ]
    [[ "$output" == '{"discovered":[]}' ]]
}

@test "json_emit_summary: produces valid JSON" {
    run _source_json 'typeset -g ATM_DISCOVERED_FILE="/nonexistent"; typeset -g ATM_DISABLED_FILE="/nonexistent"; json_emit_summary'
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/python3 -m json.tool > /dev/null
}
