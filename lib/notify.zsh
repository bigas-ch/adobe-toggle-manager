#!/bin/zsh
# === lib/notify.zsh — macOS Notification Center via osascript ===
# Module responsibility: notify function (argv binding against AppleScript injection).
#
# Dependencies: config (config_get), Default DEFAULT_NOTIFICATIONS.

notify() {
    local title="$1" message="$2"
    local mode
    mode=$(config_get notifications 2>/dev/null)
    [[ -z "$mode" ]] && mode="$DEFAULT_NOTIFICATIONS"
    [[ "$mode" == "off" ]] && return 0
    # argv binding against AppleScript injection
    /usr/bin/osascript \
        -e 'on run argv' \
        -e '  display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' \
        -- "$title" "$message" 2>/dev/null
}
