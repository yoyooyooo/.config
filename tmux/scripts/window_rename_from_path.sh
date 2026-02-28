#!/usr/bin/env bash
set -euo pipefail

# Usage: window_rename_from_path.sh <window_id> <pane_id>
window_id="${1:-}"
pane_id="${2:-}"

[[ -n "$window_id" ]] || exit 0

# Skip during restore cooldown window to avoid racing tmux-resurrect.
block_until="$(tmux show-option -gqv @window_auto_name_block_until 2>/dev/null || true)"
if [[ "$block_until" =~ ^[0-9]+$ ]]; then
  now_epoch="$(date +%s)"
  if (( now_epoch < block_until )); then
    exit 0
  fi
fi

# Skip if window automatic rename is disabled (usually means custom/restored name).
auto_rename="$(tmux display-message -p -t "$window_id" '#{automatic-rename}' 2>/dev/null || true)"
if [[ "$auto_rename" == "0" || "$auto_rename" == "off" ]]; then
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
