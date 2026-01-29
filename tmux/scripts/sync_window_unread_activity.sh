#!/usr/bin/env bash
set -euo pipefail

window_id="${1:-}"
pane_id="${2:-}"

if [[ -z "${window_id}" && -n "${pane_id}" ]]; then
  window_id="$(tmux display-message -p -t "${pane_id}" '#{window_id}' 2>/dev/null || true)"
fi

[[ -n "${window_id}" ]] || exit 0

has_unread="$(
  tmux list-panes -t "${window_id}" -F '#{?#{==:#{@unread_pane_activity},1},1,0}' 2>/dev/null \
    | awk '$1 == 1 { found=1; exit } END { print (found ? 1 : 0) }' || echo 0
)"

if [[ "${has_unread}" == "1" ]]; then
  tmux set -w -t "${window_id}" @unread_activity 1 2>/dev/null || true
else
  tmux set -w -t "${window_id}" @unread_activity 0 2>/dev/null || true
fi

