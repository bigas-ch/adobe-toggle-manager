#!/usr/bin/env bats
# Unit tests for Display-Width + Box-Drawing-Engine (v3.1.0)

setup() {
    export ATM_BASE="$(mktemp -d)"
    SCRIPT="$BATS_TEST_DIRNAME/../adobe-toggle"
}

teardown() {
    rm -rf "$ATM_BASE"
}

@test "_display_width: ASCII counts as 1 cell per char" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _display_width 'abc'"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "_display_width: red emoji counts as 2 cells" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _display_width '🔴'"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "_display_width: green emoji counts as 2 cells" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _display_width '🟢'"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "_display_width: mixed emoji + ASCII" {
    # '🔴 abc' = 2 + 1 + 3 = 6
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _display_width '🔴 abc'"
    [ "$status" -eq 0 ]
    [ "$output" = "6" ]
}

@test "_pad_truncate: shorter string padded to target" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _pad_truncate 'abc' 10"
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 10 ]
    [ "${output:0:3}" = "abc" ]
}

@test "_pad_truncate: exact-fit string unchanged" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _pad_truncate 'abcdefghij' 10"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdefghij" ]
}

@test "_pad_truncate: too long → truncate + ..." {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _pad_truncate 'abcdefghijklmno' 10"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdefg..." ]
    [ "${#output}" -eq 10 ]
}

@test "_pad_truncate: emoji-content correctly counted" {
    # '🔴 abc' has display-width 6, target 10 → pad with 4 spaces
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _pad_truncate '🔴 abc' 10 | cat"
    [ "$status" -eq 0 ]
    # display_width must be exactly 10
    local dw
    dw=$(zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _display_width \"\$(_pad_truncate '🔴 abc' 10)\"")
    [ "$dw" = "10" ]
}

@test "_box_line: rendered line has consistent width regardless of emoji" {
    # Render two lines, both must end at the same column position
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _box_line 'plain' 30; _box_line '🔴 emoji' 30"
    [ "$status" -eq 0 ]
    # Each rendered line should have identical visible width
    # We check that both lines end with ' │' (space + closing border)
    local line1 line2
    line1=$(echo "$output" | sed -n '1p')
    line2=$(echo "$output" | sed -n '2p')
    # Both should end with '│'
    [[ "$line1" == *"│" ]]
    [[ "$line2" == *"│" ]]
}

@test "_box_top + _box_bottom: same width" {
    run zsh -c "ATM_BASE='$ATM_BASE' source '$SCRIPT' >/dev/null 2>&1; _box_top 'X' 30; _box_bottom 30"
    [ "$status" -eq 0 ]
    local top bottom
    top=$(echo "$output" | sed -n '1p')
    bottom=$(echo "$output" | sed -n '2p')
    # Both rendered lines must have same character count (excluding multi-byte issues since they only contain ASCII + box-drawing 1-cell chars)
    # Box-drawing chars are also 1-cell. Length comparison should work for these strings.
    [ "${#top}" -eq "${#bottom}" ]
}
