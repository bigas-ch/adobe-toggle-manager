#!/usr/bin/env bats
# Tests for scripts/git-hooks/pre-push (v4.9.0).
# Strategy: each test builds a temporary git repo with controlled history,
# writes tag refs to the hook's stdin, checks exit + output.

load helpers/sandbox.bash

setup() {
    HOOK="$BATS_TEST_DIRNAME/../scripts/git-hooks/pre-push"
    [ -f "$HOOK" ]
    REPO=$(mktemp -d -t atm_hook_XXXXXX)
    cd "$REPO"
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
}

teardown() {
    [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"
}

# Helper: append a commit with given message
_commit() {
    local msg="$1"
    echo "$RANDOM" > file.txt
    git add file.txt
    git commit -q -m "$msg"
}

# Helper: feed a tag-push to the hook stdin
_push_tag() {
    local tag="$1"
    local sha
    sha=$(git rev-parse "$tag")
    printf 'refs/tags/%s %s refs/tags/%s 0000000000000000000000000000000000000000\n' \
        "$tag" "$sha" "$tag" | "$HOOK"
}

@test "MINOR tag (v1.1.0) with feat: commit is ok" {
    _commit "chore: init"
    git tag v1.0.0
    _commit "feat: new thing"
    git tag v1.1.0
    run _push_tag "v1.1.0"
    [ "$status" -eq 0 ]
}

@test "PATCH tag (v1.0.1) without feat: commit is ok" {
    _commit "chore: init"
    git tag v1.0.0
    _commit "fix: bug"
    git tag v1.0.1
    run _push_tag "v1.0.1"
    [ "$status" -eq 0 ]
}

@test "PATCH tag (v1.0.1) WITH feat: commit is rejected (semver violation)" {
    _commit "chore: init"
    git tag v1.0.0
    _commit "feat: sneaky feature"
    git tag v1.0.1
    run _push_tag "v1.0.1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"semver violation"* ]]
    [[ "$output" == *"v1.0.1"* ]]
    [[ "$output" == *"sneaky feature"* ]]
}

@test "PATCH tag (v1.0.2) with several feat: commits shows all of them" {
    _commit "chore: init"
    git tag v1.0.0
    _commit "feat: one"
    _commit "feat: two"
    _commit "fix: also"
    git tag v1.0.2
    run _push_tag "v1.0.2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"feat: one"* ]]
    [[ "$output" == *"feat: two"* ]]
    # fix: stays out
    [[ "$output" != *"fix: also"* ]]
}

@test "MAJOR tag (v2.0.0) with feat: is ok (Z=0 is always allowed)" {
    _commit "chore: init"
    git tag v1.0.0
    _commit "feat: breaking"
    git tag v2.0.0
    run _push_tag "v2.0.0"
    [ "$status" -eq 0 ]
}

@test "Non-semver tag (rc tag) is ignored" {
    _commit "chore: init"
    _commit "feat: rc-feature"
    git tag v1.0.0-rc1
    run _push_tag "v1.0.0-rc1"
    [ "$status" -eq 0 ]
}

@test "Very first tag (no predecessor) → no check" {
    _commit "chore: init"
    _commit "feat: first feature"
    git tag v0.0.1
    run _push_tag "v0.0.1"
    [ "$status" -eq 0 ]
}

@test "Override via ATM_SKIP_PRE_PUSH=1 passes through despite violation" {
    _commit "chore: init"
    git tag v1.0.0
    _commit "feat: bypass"
    git tag v1.0.1
    sha=$(git rev-parse v1.0.1)
    run env ATM_SKIP_PRE_PUSH=1 bash -c "printf 'refs/tags/v1.0.1 %s refs/tags/v1.0.1 0000000000000000000000000000000000000000\n' '$sha' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped"* ]]
}

@test "Branch push (no tag) is ignored (even with feat commits)" {
    _commit "chore: init"
    _commit "feat: branch-feature"
    sha=$(git rev-parse HEAD)
    # Branch ref format
    run bash -c "printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' '$sha' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "Hook script is syntactically valid zsh" {
    run /bin/zsh -n "$HOOK"
    [ "$status" -eq 0 ]
}

# === PD-03 (v4.15.1): doc-consistency Hard-Fail ===============================

@test "PD-03: doc-consistency tests missing → warning, but no abort (skipping)" {
    # Test repo has NO tests/test_integration_doc_consistency.bats →
    # hook prints a warning but passes through (otherwise the hook could not
    # run in foreign repos)
    _commit "chore: init"
    git tag v1.0.0
    run _push_tag "v1.0.0"
    [ "$status" -eq 0 ]
    [[ "$output" == *"doc-consistency tests not found"* ]] || \
        [[ "$output" == *"skipping"* ]]
}

# Helper: creates a mock bats that drives the exit code from env.
# Avoids the bats-in-bats recursion problem (TMPDIR conflict with the parent).
_make_mock_bats() {
    local exit_code="${1:-0}"
    local mock="$REPO/mock_bats"
    cat > "$mock" <<EOF
#!/bin/bash
echo "mock-bats called with: \$*"
echo "1..1"
if [[ "$exit_code" == "0" ]]; then
    echo "ok 1 mock-test"
    exit 0
else
    echo "not ok 1 mock-test (simulated)"
    exit 1
fi
EOF
    /bin/chmod +x "$mock"
    echo "$mock"
}

@test "PD-03: doc-consistency test green → tag push allowed" {
    _commit "chore: init"
    /bin/mkdir -p tests
    : > tests/test_integration_doc_consistency.bats
    git add tests
    git commit -q -m "test: add doc-consistency stub"
    git tag v1.0.0
    local mock=$(_make_mock_bats 0)
    sha=$(git rev-parse v1.0.0)
    run env ATM_BATS_BIN="$mock" bash -c "printf 'refs/tags/v1.0.0 %s refs/tags/v1.0.0 0000000000000000000000000000000000000000\n' '$sha' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"doc-consistency OK"* ]]
}

@test "PD-03: doc-consistency test red → tag push aborted" {
    _commit "chore: init"
    /bin/mkdir -p tests
    : > tests/test_integration_doc_consistency.bats
    git add tests
    git commit -q -m "test: add failing doc-test"
    git tag v1.0.0
    local mock=$(_make_mock_bats 1)
    sha=$(git rev-parse v1.0.0)
    run env ATM_BATS_BIN="$mock" bash -c "printf 'refs/tags/v1.0.0 %s refs/tags/v1.0.0 0000000000000000000000000000000000000000\n' '$sha' | '$HOOK'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"doc-consistency tests FAIL"* ]]
    [[ "$output" == *"aborted"* ]]
}

@test "PD-03: doc-consistency red + ATM_SKIP_PRE_PUSH=1 → override allowed" {
    _commit "chore: init"
    /bin/mkdir -p tests
    : > tests/test_integration_doc_consistency.bats
    git add tests
    git commit -q -m "test: failing doc-test"
    git tag v1.0.0
    local mock=$(_make_mock_bats 1)
    sha=$(git rev-parse v1.0.0)
    run env ATM_SKIP_PRE_PUSH=1 ATM_BATS_BIN="$mock" bash -c "printf 'refs/tags/v1.0.0 %s refs/tags/v1.0.0 0000000000000000000000000000000000000000\n' '$sha' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped"* ]]
}

@test "PD-03: branch push does NOT trigger doc-consistency (tag push only)" {
    _commit "chore: init"
    /bin/mkdir -p tests
    : > tests/test_integration_doc_consistency.bats
    git add tests
    git commit -q -m "test: stub"
    sha=$(git rev-parse HEAD)
    local mock=$(_make_mock_bats 1)
    # Branch push (no tag) → doc-consistency is NOT called → status 0
    run env ATM_BATS_BIN="$mock" bash -c "printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' '$sha' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"doc-consistency"* ]]
}
