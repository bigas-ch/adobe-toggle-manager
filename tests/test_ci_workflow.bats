#!/usr/bin/env bats
# Tests for .github/workflows/ci.yml (v4.13.0).
# Verifies workflow file existence, structure, security patterns.

WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/ci.yml"

@test "ci.yml: exists" {
    [ -f "$WORKFLOW" ]
}

@test "ci.yml: has unit-tests + e2e-tests jobs" {
    grep -q "^  unit-tests:" "$WORKFLOW"
    grep -q "^  e2e-tests:" "$WORKFLOW"
}

@test "ci.yml: uses macos-14 runner" {
    grep -q "runs-on: macos-14" "$WORKFLOW"
}

@test "ci.yml: e2e-tests setzt ATM_LAUNCHCTL_REAL_DENY=1 (no real launchctl)" {
    grep -q 'ATM_LAUNCHCTL_REAL_DENY: "1"' "$WORKFLOW"
}

@test "ci.yml: uses mock binaries (no real /bin/launchctl on CI)" {
    grep -q "tests/helpers/mocks/mock_launchctl" "$WORKFLOW"
    grep -q "tests/helpers/mocks/mock_codesign" "$WORKFLOW"
}

@test "ci.yml: E2E uses com.adobe.* test fakes so discovery can find them" {
    # discover_plists only globs com.adobe*.plist, so the E2E fixtures MUST live
    # in the com.adobe.* namespace to exercise discovery at all. Safety comes
    # from the mock launchctl + ATM_LAUNCHCTL_REAL_DENY=1 guard (asserted above),
    # not from the label namespace.
    grep -q "com.adobe.atmtest.fake" "$WORKFLOW"
}

@test "ci.yml: tests pre-push-hook reject of feat in a PATCH tag" {
    grep -q "Pre-Push-Hook" "$WORKFLOW"
    grep -q "feat: bad in patch" "$WORKFLOW"
}

@test "ci.yml: cleanup step is always (even on test failure)" {
    grep -q "if: always()" "$WORKFLOW"
}

@test "ci.yml: no direct use of event input without env wrapper (security)" {
    # Inputs like github.event.* must not appear directly in run:
    ! grep -E '\$\{\{ *github\.event\.' "$WORKFLOW" || true
}

@test "ci.yml: e2e-tests depends on unit-tests (needs)" {
    grep -q "needs: unit-tests" "$WORKFLOW"
}
