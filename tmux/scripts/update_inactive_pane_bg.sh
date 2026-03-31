#!/usr/bin/env bash
set -euo pipefail

target_window_id="${1:-}"
if [[ -z "${target_window_id}" ]]; then
  exit 0
fi

set_window_option_if_needed() {
  local option_name="$1"
  local desired_value="$2"
  local current_value

  current_value="$(tmux show-options -w -t "${target_window_id}" -v "${option_name}" 2>/dev/null || true)"
  if [[ "${current_value}" != "${desired_value}" ]]; then
    tmux set-window-option -t "${target_window_id}" "${option_name}" "${desired_value}"
  fi
}

panes="$(tmux display-message -p -t "${target_window_id}" "#{window_panes}" 2>/dev/null || true)"
if [[ -z "${panes}" ]]; then
  exit 0
fi

if [[ "${panes}" =~ ^[0-9]+$ ]] && (( panes > 1 )); then
  # 多 pane 时只突出 active pane，inactive pane 透出终端默认底色。
  set_window_option_if_needed "window-style" "bg=default"
  set_window_option_if_needed "window-active-style" "bg=black"
else
  set_window_option_if_needed "window-style" "bg=default"
  set_window_option_if_needed "window-active-style" "bg=default"
fi
