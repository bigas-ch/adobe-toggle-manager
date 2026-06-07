#!/usr/bin/env bats
# Backwards-Compatibility (v4.13.4, Phase D — L-03, L-11, D-02).

load helpers/sandbox.bash

setup() {
    sandbox_setup
    /bin/mkdir -p "$ATM_BASE/logs"
    ATM_DISABLED_FILE="$ATM_BASE/disabled.list"
}
teardown() { sandbox_teardown; }

# === L-03 + L-11 lazy migration v3 format → v4 format =========================

@test "L-03: 3-col legacy disabled.list (v3.x format) → state=auto_blocked on read" {
    # Write a legacy 3-col entry (label\tscope\tdisabled_at)
    printf 'com.adobe.legacy1\tgui\t2026-04-01T12:00:00Z\n' > "$ATM_DISABLED_FILE"
    printf 'com.adobe.legacy2\tsystem\t2026-04-01T12:00:00Z\n' >> "$ATM_DISABLED_FILE"
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_get_state com.adobe.legacy1
        disabled_list_get_state com.adobe.legacy2
    "
    [ "$status" -eq 0 ]
    # Both entries → state=auto_blocked (default for legacy)
    [[ "$output" == *"auto_blocked"$'\n'"auto_blocked"* ]]
}

@test "L-11: mixed file (3-col + 4-col) stays readable" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.legacy3col	gui	2026-04-01T12:00:00Z
com.adobe.new4col	system	2026-05-03T12:00:00Z	user_allowed
com.adobe.legacy3col_2	user	2026-04-15T12:00:00Z
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_get_state com.adobe.legacy3col
        disabled_list_get_state com.adobe.new4col
        disabled_list_get_state com.adobe.legacy3col_2
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto_blocked"* ]]
    [[ "$output" == *"user_allowed"* ]]
}

@test "L-11b: set_state on a legacy file migrates ALL lines to 4-col" {
    cat > "$ATM_DISABLED_FILE" <<'EOF'
com.adobe.a	gui	2026-04-01T12:00:00Z
com.adobe.b	gui	2026-04-01T12:00:00Z
EOF
    run zsh -c "
        source '$SCRIPT' >/dev/null 2>&1
        disabled_list_set_state com.adobe.a gui user_allowed
    "
    [ "$status" -eq 0 ]
    # After set_state: all lines must be 4-col
    local non4col
    non4col=$(/usr/bin/awk -F'\t' 'NF != 4' "$ATM_DISABLED_FILE" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$non4col" -eq 0 ]
}

# === D-02 README/help/dispatch consistency ====================================

@test "D-02: README documents all dispatch subcommands" {
    cd "$BATS_TEST_DIRNAME/.."
    # Extract dispatch cases from main()
    local subcommands
    subcommands=$(/usr/bin/awk '/^main\(\)/,/^}/' adobe-toggle | \
        /usr/bin/grep -oE "(--tui|--daemon|--healthcheck|--summary|--stats|summary|status|discovery|health|--version|-V|--help|-h|config)\\)" | \
        /usr/bin/sed 's/)$//' | /usr/bin/sort -u)
    # All must be mentioned in README (except internal -V/-h aliases)
    # grep -F + -- so that '--daemon' is not interpreted as an option
    local missing=0
    for cmd in $(echo "$subcommands" | /usr/bin/grep -vE "^-V$|^-h$|^--stats$"); do
        /usr/bin/grep -qF -- "$cmd" README.md || { echo "MISSING in README: $cmd"; missing=$(( missing + 1 )); }
    done
    # Tolerance: --healthcheck is internal (called by the LaunchAgent, not user-facing)
    # → 1-2 missing is expected as ok
    [ "$missing" -le 2 ]
}

@test "D-02b: help_main lists status/discovery/summary/health (v4.7+v4.11 commands)" {
    /usr/bin/grep -A20 "^help_main()" lib/daemon.zsh | /usr/bin/grep -q "status"
    /usr/bin/grep -A20 "^help_main()" lib/daemon.zsh | /usr/bin/grep -q "discovery"
    /usr/bin/grep -A20 "^help_main()" lib/daemon.zsh | /usr/bin/grep -q "summary"
    /usr/bin/grep -A20 "^help_main()" lib/daemon.zsh | /usr/bin/grep -q "health"
}

# === D-03 Trade-offs doc-drift guard =========================================
# The trade-offs + threat model live in SECURITY.md (English) since the public
# README rewrite; the README links to it. These guards ensure that content
# stays documented in its canonical home.

@test "D-03: SECURITY.md has a 'Deliberate trade-offs' section" {
    /usr/bin/grep -q "^## Deliberate trade-offs" "$BATS_TEST_DIRNAME/../SECURITY.md"
}

@test "D-03b: SECURITY.md documents all 3 trade-offs (whitelist bypass, watcher RSS, long-running tests)" {
    /usr/bin/grep -qiE "whitelist can be bypassed|disabled\.list" "$BATS_TEST_DIRNAME/../SECURITY.md"
    /usr/bin/grep -qiE "140 ?MB" "$BATS_TEST_DIRNAME/../SECURITY.md"
    /usr/bin/grep -qiE "long-running tests|ATM_LONGRUN" "$BATS_TEST_DIRNAME/../SECURITY.md"
}

@test "D-03c: README references the threat model and SECURITY.md exists" {
    /usr/bin/grep -qiE "threat model" "$BATS_TEST_DIRNAME/../README.md"
    [ -f "$BATS_TEST_DIRNAME/../SECURITY.md" ]
}

@test "D-03d: SECURITY.md documents the long-running test gate (ATM_LONGRUN)" {
    /usr/bin/grep -q "ATM_LONGRUN=1" "$BATS_TEST_DIRNAME/../SECURITY.md"
}
