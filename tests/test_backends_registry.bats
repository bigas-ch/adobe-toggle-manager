#!/usr/bin/env bats
# Tests for lib/backend_registry.zsh — registry CRUD + conformance check.

load helpers/sandbox.bash

setup() {
    sandbox_setup
    REG="$BATS_TEST_DIRNAME/../lib/backend_registry.zsh"
    [[ -f "$REG" ]] || skip "registry not found at $REG"

    # Helper: writes a conforming mock backend to $ATM_BASE/mock_backend_<name>.zsh
    # and echoes its path.
    write_conforming_backend() {
        local name="$1"
        local file="$ATM_BASE/mock_backend_${name}.zsh"
        cat > "$file" <<EOF
${name}__name()         { print -- "$name"; }
${name}__discover()     { printf 'type1\tid1\tuser\t/tmp/foo\n'; }
${name}__block()        { return 0; }
${name}__allow()        { return 0; }
${name}__is_blocked()   { return 1; }
${name}__kill_running() { return 0; }
EOF
        echo "$file"
    }
}
teardown() { sandbox_teardown; }

# === Registry CRUD ===

@test "backend_register adds a conforming backend" {
    write_conforming_backend foo > /dev/null
    run zsh -c "
        source '$REG'
        backend_register foo '$ATM_BASE/mock_backend_foo.zsh'
        echo \"exit=\$?\"
        echo \"count=\$(backend_count)\"
        backend_is_registered foo && echo is_registered=yes || echo is_registered=no
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    [[ "$output" == *"count=1"* ]]
    [[ "$output" == *"is_registered=yes"* ]]
}

@test "backend_register rejects file that does not exist" {
    run zsh -c "source '$REG'; backend_register foo /no/such/file"
    [ "$status" -eq 1 ]
    [[ "$output" == *"file not found"* ]]
}

@test "backend_register rejects invalid name (uppercase)" {
    write_conforming_backend foo > /dev/null
    run zsh -c "source '$REG'; backend_register FOO '$ATM_BASE/mock_backend_foo.zsh'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid name"* ]]
}

@test "backend_register rejects invalid name (with dash)" {
    write_conforming_backend foo > /dev/null
    run zsh -c "source '$REG'; backend_register foo-bar '$ATM_BASE/mock_backend_foo.zsh'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid name"* ]]
}

@test "backend_register fails conformance check when function missing" {
    # Write a backend WITHOUT a block function.
    cat > "$ATM_BASE/mock_broken.zsh" <<'EOF'
broken__name()         { print -- "broken"; }
broken__discover()     { :; }
# (block intentionally missing)
broken__allow()        { return 0; }
broken__is_blocked()   { return 1; }
broken__kill_running() { return 0; }
EOF
    run zsh -c "source '$REG'; backend_register broken '$ATM_BASE/mock_broken.zsh'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing functions"* ]]
    [[ "$output" == *"broken__block"* ]]
}

@test "backend_register lists all missing functions in error" {
    cat > "$ATM_BASE/mock_minimal.zsh" <<'EOF'
minimal__name()     { print -- "minimal"; }
minimal__discover() { :; }
EOF
    run zsh -c "source '$REG'; backend_register minimal '$ATM_BASE/mock_minimal.zsh'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"minimal__block"* ]]
    [[ "$output" == *"minimal__allow"* ]]
    [[ "$output" == *"minimal__is_blocked"* ]]
    [[ "$output" == *"minimal__kill_running"* ]]
}

# === backend_list, backend_count, backend_is_registered ===

@test "backend_list returns empty when no backends registered" {
    run zsh -c "source '$REG'; backend_list"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "backend_list returns names in registration order" {
    write_conforming_backend a > /dev/null
    write_conforming_backend b > /dev/null
    write_conforming_backend c > /dev/null
    run zsh -c "
        source '$REG'
        backend_register a '$ATM_BASE/mock_backend_a.zsh'
        backend_register b '$ATM_BASE/mock_backend_b.zsh'
        backend_register c '$ATM_BASE/mock_backend_c.zsh'
        backend_list
    "
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "a" ]]
    [[ "${lines[1]}" == "b" ]]
    [[ "${lines[2]}" == "c" ]]
}

@test "backend_count tracks registered backends" {
    write_conforming_backend x > /dev/null
    write_conforming_backend y > /dev/null
    run zsh -c "
        source '$REG'
        echo before=\$(backend_count)
        backend_register x '$ATM_BASE/mock_backend_x.zsh' >/dev/null
        echo after_x=\$(backend_count)
        backend_register y '$ATM_BASE/mock_backend_y.zsh' >/dev/null
        echo after_y=\$(backend_count)
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"before=0"* ]]
    [[ "$output" == *"after_x=1"* ]]
    [[ "$output" == *"after_y=2"* ]]
}

@test "backend_unregister removes from registry" {
    write_conforming_backend foo > /dev/null
    run zsh -c "
        source '$REG'
        backend_register foo '$ATM_BASE/mock_backend_foo.zsh' >/dev/null
        echo before=\$(backend_count)
        backend_unregister foo
        echo after=\$(backend_count)
        backend_is_registered foo && echo still_registered || echo removed
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"before=1"* ]]
    [[ "$output" == *"after=0"* ]]
    [[ "$output" == *"removed"* ]]
}

# === backend_dispatch ===

@test "backend_dispatch calls the named function" {
    write_conforming_backend foo > /dev/null
    run zsh -c "
        source '$REG'
        backend_register foo '$ATM_BASE/mock_backend_foo.zsh' >/dev/null
        backend_dispatch foo name
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "foo" ]]
}

@test "backend_dispatch returns 127 for unregistered backend" {
    run zsh -c "source '$REG'; backend_dispatch nonexistent name"
    [ "$status" -eq 127 ]
    [[ "$output" == *"not registered"* ]]
}

@test "backend_dispatch returns 127 for unknown function" {
    write_conforming_backend foo > /dev/null
    run zsh -c "
        source '$REG'
        backend_register foo '$ATM_BASE/mock_backend_foo.zsh' >/dev/null
        backend_dispatch foo bogus_function
    "
    [ "$status" -eq 127 ]
    [[ "$output" == *"function not found"* ]]
}

@test "backend_dispatch propagates exit code from backend function" {
    cat > "$ATM_BASE/mock_exit42.zsh" <<'EOF'
exit42__name()         { print -- "exit42"; }
exit42__discover()     { :; }
exit42__block()        { return 42; }
exit42__allow()        { return 0; }
exit42__is_blocked()   { return 1; }
exit42__kill_running() { return 0; }
EOF
    run zsh -c "
        source '$REG'
        backend_register exit42 '$ATM_BASE/mock_exit42.zsh' >/dev/null
        backend_dispatch exit42 block
    "
    [ "$status" -eq 42 ]
}

@test "backend_dispatch passes args through to backend function" {
    cat > "$ATM_BASE/mock_argecho.zsh" <<'EOF'
argecho__name()         { print -- "argecho"; }
argecho__discover()     { :; }
argecho__block()        { print -- "block: $*"; }
argecho__allow()        { return 0; }
argecho__is_blocked()   { return 1; }
argecho__kill_running() { return 0; }
EOF
    run zsh -c "
        source '$REG'
        backend_register argecho '$ATM_BASE/mock_argecho.zsh' >/dev/null
        backend_dispatch argecho block agent com.foo user /p1
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "block: agent com.foo user /p1" ]]
}

# === backend_discover_all ===

@test "backend_discover_all prefixes output with backend name" {
    write_conforming_backend alpha > /dev/null
    run zsh -c "
        source '$REG'
        backend_register alpha '$ATM_BASE/mock_backend_alpha.zsh' >/dev/null
        backend_discover_all
    "
    [ "$status" -eq 0 ]
    # mock-backend's discover outputs 'type1\tid1\tuser\t/tmp/foo'
    # backend_discover_all prefixes with 'alpha\t'
    [[ "$output" == *"alpha"$'\t'"type1"$'\t'"id1"$'\t'"user"$'\t'"/tmp/foo"* ]]
}

@test "backend_discover_all aggregates outputs from multiple backends in order" {
    cat > "$ATM_BASE/mock_a.zsh" <<'EOF'
a__name()         { print -- "a"; }
a__discover()     { print -- "T\tA1\tuser\t/p"; }
a__block()        { return 0; }
a__allow()        { return 0; }
a__is_blocked()   { return 1; }
a__kill_running() { return 0; }
EOF
    cat > "$ATM_BASE/mock_b.zsh" <<'EOF'
b__name()         { print -- "b"; }
b__discover()     { print -- "T\tB1\tgui\t/q"; }
b__block()        { return 0; }
b__allow()        { return 0; }
b__is_blocked()   { return 1; }
b__kill_running() { return 0; }
EOF
    run zsh -c "
        source '$REG'
        backend_register a '$ATM_BASE/mock_a.zsh' >/dev/null
        backend_register b '$ATM_BASE/mock_b.zsh' >/dev/null
        backend_discover_all
    "
    [ "$status" -eq 0 ]
    # First line should come from 'a', second from 'b' (registration order).
    [[ "${lines[0]}" == "a"$'\t'"T"$'\t'"A1"$'\t'"user"$'\t'"/p" ]]
    [[ "${lines[1]}" == "b"$'\t'"T"$'\t'"B1"$'\t'"gui"$'\t'"/q" ]]
}

@test "backend_discover_all returns empty when no backends registered" {
    run zsh -c "source '$REG'; backend_discover_all"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "backend_discover_all skips empty discover lines" {
    cat > "$ATM_BASE/mock_empty.zsh" <<'EOF'
empty__name()         { print -- "empty"; }
empty__discover()     { :; }   # produces no output
empty__block()        { return 0; }
empty__allow()        { return 0; }
empty__is_blocked()   { return 1; }
empty__kill_running() { return 0; }
EOF
    run zsh -c "
        source '$REG'
        backend_register empty '$ATM_BASE/mock_empty.zsh' >/dev/null
        backend_discover_all
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
