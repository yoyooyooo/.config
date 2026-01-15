#!/usr/bin/env bash
set -euo pipefail

scratch_name="${TMUX_SCRATCH_WINDOW_NAME:-scratchpad}"

current_window_id=$(tmux display-message -p '#{window_id}' 2>/dev/null || true)
scratch_window_id=$(tmux list-windows -F '#{window_id}\t#{window_name}' 2>/dev/null | awk -v name="$scratch_name" '$2 == name {print $1; exit}')

if [[ -n "${scratch_window_id:-}" ]]; then
  if [[ -n "${current_window_id:-}" && "$current_window_id" == "$scratch_window_id" ]]; then
    tmux last-window 2>/dev/null || true
  else
    tmux select-window -t "$scratch_window_id" 2>/dev/null || true
  fi
  exit 0
fi

tmux new-window -n "$scratch_name" -c "#{pane_current_path}" 2>/dev/null || true
