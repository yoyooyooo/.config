#!/usr/bin/env bash
set -euo pipefail

session_id="${1:-}"

if [[ -z "${session_id}" ]]; then
  session_id="$(tmux display-message -p '#{session_id}' 2>/dev/null || true)"
fi

[[ -z "${session_id}" ]] && exit 0

count=0
while IFS=$'\t' read -r _win_id custom_unread; do
  if [[ "${custom_unread:-0}" == "1" ]]; then
    count=$((count + 1))
  fi
done < <(tmux list-windows -t "${session_id}" -F $'#{window_id}\t#{?#{==:#{@unread_activity},1},1,0}' 2>/dev/null || true)

if (( count > 0 )); then
  printf '#[fg=colour208,bold]●%d#[default]' "${count}"
fi
