#!/usr/bin/env bash
set -euo pipefail

# Usage: window_rename_from_path.sh <window_id> <pane_id>
window_id="${1:-}"
pane_id="${2:-}"

[[ -n "$window_id" ]] || exit 0

# Skip if the window has already been manually renamed.
renamed_flag="$(tmux display-message -p -t "$window_id" '#{window_renamed_flag}' 2>/dev/null || true)"
if [[ "$renamed_flag" == "1" ]]; then
  exit 0
fi

pane_path=""
if [[ -n "$pane_id" ]]; then
  pane_path="$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null || true)"
fi
if [[ -z "$pane_path" ]]; then
  fallback_pane="$(tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$fallback_pane" ]]; then
    pane_path="$(tmux display-message -p -t "$fallback_pane" '#{pane_current_path}' 2>/dev/null || true)"
  fi
fi
[[ -n "$pane_path" ]] || exit 0

name="$(~/.config/tmux/scripts/window_auto_name.sh "$pane_path" 2>/dev/null || true)"
[[ -n "$name" ]] || exit 0

tmux rename-window -t "$window_id" "$name" 2>/dev/null || true
