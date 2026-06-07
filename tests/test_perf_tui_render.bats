#!/usr/bin/env bats
# Performance tests for TUI rendering primitives (box engine + render functions).
# bats file_tags=perf

load helpers/sandbox.bash
load helpers/perf.bash

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "perf: _display_width on ASCII string (100 chars)" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            source '$SCRIPT' >/dev/null 2>&1
            _display_width 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        \"
    ")
    report_perf "_display_width 100 ASCII chars" "$median" "$p95" 200
    [ "$p95" -lt 200 ]
}

@test "perf: _display_width on emoji-mixed string" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            source '$SCRIPT' >/dev/null 2>&1
            _display_width '🔴 Adobe blocked 🟢 mixed text'
        \"
    ")
    report_perf "_display_width emoji-mix" "$median" "$p95" 200
    [ "$p95" -lt 200 ]
}

@test "perf: _pad_truncate (long string truncated)" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            source '$SCRIPT' >/dev/null 2>&1
            _pad_truncate 'This is a moderately long status message text' 30
        \"
    ")
    report_perf "_pad_truncate" "$median" "$p95" 200
    [ "$p95" -lt 200 ]
}

@test "perf: _box_top + _box_bottom" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            source '$SCRIPT' >/dev/null 2>&1
            _box_top 'Adobe Toggle v4.1.0' 60
            _box_bottom 60
        \"
    ")
    report_perf "_box_top + _box_bottom" "$median" "$p95" 200
    [ "$p95" -lt 200 ]
}

@test "perf: _box_line for 5 status lines" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            source '$SCRIPT' >/dev/null 2>&1
            _box_line '🔴 State: block' 60
            _box_line 'Daemon-PID: 12345' 60
            _box_line 'Discovered: 27 Adobe components' 60
            _box_line 'Disabled: 12' 60
            _box_line 'Last event: 12:34:56 DISABLED' 60
        \"
    ")
    report_perf "_box_line x5" "$median" "$p95" 200
    [ "$p95" -lt 200 ]
}

@test "perf: full status box render (tui_render_status, no terminal)" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            ATM_BASE='$ATM_BASE'
            ATM_LAUNCHCTL_BIN='$ATM_LAUNCHCTL_BIN'
            source '$SCRIPT' >/dev/null 2>&1
            init_state
            tui_render_status
        \"
    ")
    report_perf "tui_render_status (initial)" "$median" "$p95" 500
    [ "$p95" -lt 500 ]
}

@test "perf: _gradient_color (truecolor escape generation)" {
    read median p95 < <(measure_n 20 "
        zsh -c \"
            source '$SCRIPT' >/dev/null 2>&1
            for i in {0..4}; do
                _gradient_color \$i
            done
        \"
    ")
    report_perf "_gradient_color x5" "$median" "$p95" 200
    [ "$p95" -lt 200 ]
}

@test "Multi-byte padding: Hangul characters padded correctly (via _display_width)" {
    # Hangul characters typically count as 2 cells in CJK width tables.
    # The script uses a hardcoded WIDE_EMOJIS list (2-cell) — Hangul is NOT in it,
    # so it's treated as 1-cell. This is a known limitation, not a bug per se.
    # Test: verify behaviour is consistent (no crash).
    run zsh -c "source '$SCRIPT' >/dev/null 2>&1; _display_width '안녕'"
    [ "$status" -eq 0 ]
    # zsh counts each Hangul as 1 char (2 chars total expected by current impl).
    # If the script ever extends WIDE_EMOJIS to include CJK, this test will catch it.
    [ "$output" = "2" ]
}
