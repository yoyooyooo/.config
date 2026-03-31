#!/usr/bin/env bash
set -euo pipefail

window_id="${1:-}"
if [[ -z "${window_id}" ]]; then
  window_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
fi
if [[ -z "${window_id}" ]]; then
  exit 0
fi

set_window_option_if_needed() {
  local option_name="$1"
  local desired_value="$2"
  local current_value

  current_value="$(tmux show-options -w -t "${window_id}" -v "${option_name}" 2>/dev/null || true)"
  if [[ "${current_value}" != "${desired_value}" ]]; then
    tmux setw -t "${window_id}" "${option_name}" "${desired_value}" >/dev/null 2>&1 || true
  fi
}

window_panes="$(tmux display-message -p -t "${window_id}" '#{window_panes}' 2>/dev/null || true)"
if [[ -z "${window_panes}" ]]; then
  exit 0
fi

zoomed="$(tmux display-message -p -t "${window_id}" '#{window_zoomed_flag}' 2>/dev/null || true)"
set_window_option_if_needed "pane-border-status" "top"
set_window_option_if_needed "pane-border-lines" "single"

active_border="$(tmux show -gqv @active_border_color 2>/dev/null || true)"
if [[ -z "${active_border}" ]]; then
  active_border="#ff9f43"
fi

if [[ "${zoomed}" == "1" || "${window_panes}" -le 1 ]]; then
  set_window_option_if_needed "pane-active-border-style" "fg=colour244"
  exit 0
fi

set_window_option_if_needed "pane-active-border-style" "fg=${active_border}"

exit 0
