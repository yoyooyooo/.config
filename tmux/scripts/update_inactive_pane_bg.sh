#!/usr/bin/env bash
set -euo pipefail

target_window_id="${1:-}"
if [[ -z "${target_window_id}" ]]; then
  exit 0
fi

panes="$(tmux display-message -p -t "${target_window_id}" "#{window_panes}" 2>/dev/null || true)"
if [[ -z "${panes}" ]]; then
  exit 0
fi

inactive_bg="$(tmux show-option -gqv @inactive_pane_bg 2>/dev/null || true)"
if [[ -z "${inactive_bg}" ]]; then
  inactive_bg="#0b1220"
fi

if [[ "${panes}" =~ ^[0-9]+$ ]] && (( panes > 1 )); then
  tmux set-window-option -t "${target_window_id}" window-style "bg=${inactive_bg}"
  tmux set-window-option -t "${target_window_id}" window-active-style "bg=default"
else
  tmux set-window-option -t "${target_window_id}" window-style "bg=default"
  tmux set-window-option -t "${target_window_id}" window-active-style "bg=default"
fi

