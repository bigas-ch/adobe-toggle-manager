#!/bin/zsh
# === lib/box.zsh — TUI box-drawing engine + gradient-border animation ===
# Module responsibility: pure-rendering primitives (display-width-aware padding,
# box-drawing chars, gradient-border animation for the Live Activity box).
#
# Dependencies: none external (no log, no state — pure render).
# Consumers: lib/tui.zsh.


# === Display-width + box-drawing engine (v3.1.0) ===
# 2-cell emojis hardcoded (all other chars are 1-cell)
typeset -ga _WIDE_EMOJIS=( '🔴' '🟢' )

_display_width() {
    local s="$1"
    local n=${#s}
    local emoji
    for emoji in "${_WIDE_EMOJIS[@]}"; do
        local stripped="${s//$emoji/}"
        local extras=$(( ${#s} - ${#stripped} ))
        n=$(( n + extras ))
    done
    print -- "$n"
}

_pad_truncate() {
    local s="$1" target="$2"
    local width
    width=$(_display_width "$s")
    if (( width <= target )); then
        # Pad with spaces up to target
        local pad=$(( target - width ))
        printf '%s' "$s"
        (( pad > 0 )) && printf '%*s' "$pad" ''
    else
        # Truncate: cut chars from the end until (display_width <= target - 3), then "..."
        local cut="$s"
        while (( $(_display_width "$cut") > target - 3 )); do
            cut="${cut[1,-2]}"   # zsh: everything except the last char
        done
        printf '%s...' "$cut"
    fi
    return 0
}

# Repeat single char N times
_repeat_char() {
    local ch="$1" n="$2"
    (( n <= 0 )) && return 0
    local out=""
    local i
    for (( i=0; i<n; i++ )); do
        out+="$ch"
    done
    print -n -- "$out"
}

_box_top() {
    local title="$1" inner_width="$2"
    # ┌─ Title ──...──┐
    local title_part="─ $title "
    local title_w
    title_w=$(_display_width "$title_part")
    local rest=$(( inner_width - title_w ))
    (( rest < 0 )) && rest=0
    print -n -- "┌"
    print -n -- "$title_part"
    _repeat_char "─" "$rest"
    print -- "┐"
}

_box_bottom() {
    local inner_width="$1"
    print -n -- "└"
    _repeat_char "─" "$inner_width"
    print -- "┘"
}

_box_line() {
    local content="$1" inner_width="$2"
    # 1 char pad links + 1 char pad rechts → content_max = inner_width - 2
    local content_max=$(( inner_width - 2 ))
    local padded
    padded=$(_pad_truncate "$content" "$content_max")
    print -- "│ ${padded} │"
}

# Empty box-line of the same width
_box_empty() {
    local inner_width="$1"
    _box_line "" "$inner_width"
}

# Vertically center content lines to target_height.
# Args: source_array_name target_height result_array_name
# When content < target: padding 50/50 top+bottom (remainder goes to bottom on odd diff).
# When content > target: truncate to target.
_vertical_center() {
    local src_name="$1" target="$2" dst_name="$3"
    local -a src
    eval "src=( \"\${${src_name}[@]}\" )"
    local n=${#src[@]}
    local -a result=()
    if (( n >= target )); then
        # truncate
        local i
        for (( i=1; i<=target; i++ )); do
            result+=( "${src[i]}" )
        done
    else
        local diff=$(( target - n ))
        local above=$(( diff / 2 ))
        local below=$(( diff - above ))
        local i
        for (( i=0; i<above; i++ )); do result+=( "" ); done
        for (( i=1; i<=n; i++ )); do result+=( "${src[i]}" ); done
        for (( i=0; i<below; i++ )); do result+=( "" ); done
    fi
    eval "${dst_name}=( \"\${result[@]}\" )"
}

# === Gradient-border animation (Live Activity box) ===
# 5-color gradient (FF0000, FF8000, FFFF00, 80FF00, 00FF00) travels along the
# border strokes of the right box. CW (allow) or CCW (block), 4 chars/s.
typeset -ga GRADIENT_RGB=(
    "255;0;0"     # FF0000  red
    "255;128;0"   # FF8000  orange
    "255;255;0"   # FFFF00  yellow
    "128;255;0"   # 80FF00  light green
    "0;255;0"     # 00FF00  green
)
# 8-color fallback (for terminals without truecolor): red, yellow, yellow, green, green
typeset -ga GRADIENT_8COLOR=( "31" "33" "33" "32" "32" )

# Capability cache: 1 = truecolor supported, 0 = fallback
typeset -gi _TRUECOLOR_OK=-1

_supports_truecolor() {
    if (( _TRUECOLOR_OK == -1 )); then
        # COLORTERM=truecolor / 24bit is the standardized indicator
        if [[ "${COLORTERM:-}" == (truecolor|24bit) ]]; then
            _TRUECOLOR_OK=1
        else
            _TRUECOLOR_OK=0
        fi
    fi
    (( _TRUECOLOR_OK == 1 ))
}

# ANSI color sequence for gradient index (0..4)
_gradient_color() {
    local idx="$1"
    if _supports_truecolor; then
        printf '\033[38;2;%sm' "${GRADIENT_RGB[idx + 1]}"
    else
        printf '\033[%sm' "${GRADIENT_8COLOR[idx + 1]}"
    fi
}

# Border-position sequence built up clockwise.
# Format: each position = "row col char"
# Box layout (analogous to v3.1.7): right box starts at terminal col 62,
# top row = 1, bottom row = 9, right col = 121 (= 62 + 60 - 1).
typeset -ga _RB_BORDER
typeset -gi _RB_BORDER_N=0

_build_right_border_sequence() {
    _RB_BORDER=()
    local r c
    local left_col=62
    local right_col=121   # = 62 + 60 - 1
    local top_row=1
    local bot_row=9
    # 1) Top: cols left_col..right_col, row top_row
    _RB_BORDER+=( "$top_row $left_col ┌" )
    for (( c=left_col+1; c<right_col; c++ )); do
        _RB_BORDER+=( "$top_row $c ─" )
    done
    _RB_BORDER+=( "$top_row $right_col ┐" )
    # 2) Right vertical (rows 2..8, col right_col)
    for (( r=top_row+1; r<bot_row; r++ )); do
        _RB_BORDER+=( "$r $right_col │" )
    done
    # 3) Bottom: cols right_col..left_col reverse, row bot_row
    _RB_BORDER+=( "$bot_row $right_col ┘" )
    for (( c=right_col-1; c>left_col; c-- )); do
        _RB_BORDER+=( "$bot_row $c ─" )
    done
    _RB_BORDER+=( "$bot_row $left_col └" )
    # 4) Left vertical (rows 8..2 reverse, col left_col)
    for (( r=bot_row-1; r>top_row; r-- )); do
        _RB_BORDER+=( "$r $left_col │" )
    done
    _RB_BORDER_N=${#_RB_BORDER[@]}
}

# Writes border position i with optional color (color_idx empty = default).
_render_border_pos() {
    local i="$1" color_idx="${2:-}"
    local pos="${_RB_BORDER[i]}"
    local parts=( ${(s: :)pos} )
    local row="${parts[1]}" col="${parts[2]}" ch="${parts[3]}"
    if [[ -n "$color_idx" ]]; then
        printf '\033[%d;%dH%s%s\033[0m' "$row" "$col" "$(_gradient_color "$color_idx")" "$ch"
    else
        # Reset (default white/none)
        printf '\033[%d;%dH\033[0m%s' "$row" "$col" "$ch"
    fi
}

# Current animation offset (advances by STEP each tick)
typeset -gi _GRADIENT_OFFSET=0
# Last displayed offset — for targeted updates (clear old zone before new)
typeset -gi _GRADIENT_LAST_OFFSET=-999

# Initial render of the entire border (draw all 134 positions once in white).
# Called by tui_render_status after each full render so that the
# border strokes are initially visible. Afterwards _gradient_tick takes over
# the targeted updates.
_render_right_border_full() {
    (( _RB_BORDER_N == 0 )) && _build_right_border_sequence
    local i
    for (( i=1; i<=_RB_BORDER_N; i++ )); do
        _render_border_pos "$i" ""
    done
    # Title overlay
    printf '\033[1;64H\033[0m─ Live Activity ─'
    _GRADIENT_LAST_OFFSET=-999
}

# Targeted tick: old 5 gradient positions → default, new 5 → colored.
# Called with the current state (allow=CW, block=CCW).
#
# IMPORTANT zsh quirk: `local var` without a value prints `var=<value>` to stdout
# if var is already a local var in the same function scope.
# → declare ALL locals once at the start of the function.
_gradient_tick() {
    local state="$1"
    local step=1 k pos_idx
    (( _RB_BORDER_N == 0 )) && _build_right_border_sequence
    [[ "$state" == "block" ]] && step=-1
    # Clear the old zone (if _GRADIENT_LAST_OFFSET is valid)
    if (( _GRADIENT_LAST_OFFSET != -999 )); then
        for (( k=0; k<${#GRADIENT_RGB[@]}; k++ )); do
            pos_idx=$(( ((_GRADIENT_LAST_OFFSET + k) % _RB_BORDER_N + _RB_BORDER_N) % _RB_BORDER_N + 1 ))
            _render_border_pos "$pos_idx" ""
        done
    fi
    # Color the new zone
    for (( k=0; k<${#GRADIENT_RGB[@]}; k++ )); do
        pos_idx=$(( ((_GRADIENT_OFFSET + k) % _RB_BORDER_N + _RB_BORDER_N) % _RB_BORDER_N + 1 ))
        _render_border_pos "$pos_idx" "$k"
    done
    # Title overlay after each tick (in case position 1+2 is currently in the gradient zone)
    printf '\033[1;64H\033[0m─ Live Activity ─'
    _GRADIENT_LAST_OFFSET=$_GRADIENT_OFFSET
    _GRADIENT_OFFSET=$(( _GRADIENT_OFFSET + step ))
}
