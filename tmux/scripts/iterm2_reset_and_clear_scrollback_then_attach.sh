#!/usr/bin/env bash
set -euo pipefail

session_id="${1:-}"

# Avoid "sessions should be nested with care, unset $TMUX" if tmux env leaks in.
unset TMUX || true
unset TMUX_PANE || true

# Reset terminal state (RIS) and clear iTerm2 scrollback for this tab.
printf '\033c'
printf '\e]1337;ClearScrollback\a'

if [[ -n "${session_id:-}" ]]; then
  exec tmux attach-session -t "$session_id"
fi

exec tmux attach-session

