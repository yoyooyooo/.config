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

if [[ "${panes}" =~ ^[0-9]+$ ]] && (( panes > 1 )); then
  # 多 pane 时只突出 active pane，inactive pane 透出终端默认底色。
  tmux set-window-option -t "${target_window_id}" window-style "bg=default"
  tmux set-window-option -t "${target_window_id}" window-active-style "bg=black"
else
  tmux set-window-option -t "${target_window_id}" window-style "bg=default"
  tmux set-window-option -t "${target_window_id}" window-active-style "bg=default"
fi
