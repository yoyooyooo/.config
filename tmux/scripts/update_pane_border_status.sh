#!/usr/bin/env bash
set -euo pipefail

window_id="${1:-}"
if [[ -z "${window_id}" ]]; then
  window_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
fi
if [[ -z "${window_id}" ]]; then
  exit 0
fi

window_panes="$(tmux display-message -p -t "${window_id}" '#{window_panes}' 2>/dev/null || true)"
if [[ -z "${window_panes}" ]]; then
  exit 0
fi

zoomed="$(tmux display-message -p -t "${window_id}" '#{window_zoomed_flag}' 2>/dev/null || true)"
tmux setw -t "${window_id}" pane-border-status top >/dev/null 2>&1 || true
tmux setw -t "${window_id}" pane-border-lines single >/dev/null 2>&1 || true

active_border="$(tmux show -gqv @active_border_color 2>/dev/null || true)"
if [[ -z "${active_border}" ]]; then
  active_border="#ff9f43"
fi

if [[ "${zoomed}" == "1" || "${window_panes}" -le 1 ]]; then
  tmux setw -t "${window_id}" pane-active-border-style fg=colour244 >/dev/null 2>&1 || true
  exit 0
fi

tmux setw -t "${window_id}" pane-active-border-style "fg=${active_border}" >/dev/null 2>&1 || true

exit 0
