#!/usr/bin/env bash
set -euo pipefail

title="${1:-}"
body="${2:-}"
client_tty="${3:-}"

trigger="$(tmux show -gqv @tmux_cross_session_btt_hud_trigger 2>/dev/null || true)"
title_var="$(tmux show -gqv @tmux_cross_session_btt_hud_title_var 2>/dev/null || true)"
body_var="$(tmux show -gqv @tmux_cross_session_btt_hud_body_var 2>/dev/null || true)"

if [[ -z "${trigger:-}" ]]; then
  trigger="btt-hud-overlay"
fi
if [[ -z "${title_var:-}" ]]; then
  title_var="hud_title"
fi
if [[ -z "${body_var:-}" ]]; then
  body_var="hud_body"
fi

case "${trigger}" in
  0|false|FALSE|off|OFF|no|NO)
    exit 1
    ;;
esac

if [[ -z "${trigger:-}" ]]; then
  exit 1
fi

if timeout 1s osascript - "$trigger" "$title_var" "$body_var" "$title" "$body" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  set triggerName to item 1 of argv
  set titleVarName to item 2 of argv
  set bodyVarName to item 3 of argv
  set titleMsg to item 4 of argv
  set bodyMsg to item 5 of argv
  tell application "BetterTouchTool"
    set_string_variable titleVarName to titleMsg
    set_string_variable bodyVarName to bodyMsg
    trigger_named_async_without_response triggerName
  end tell
end run
APPLESCRIPT
then
  exit 0
fi

exit 2

