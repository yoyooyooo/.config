#!/usr/bin/env bash
set -euo pipefail

session_id="${1:-}"

if [[ -z "${session_id}" ]]; then
  session_id="$(tmux display-message -p '#{session_id}' 2>/dev/null || true)"
fi

[[ -z "${session_id}" ]] && exit 0

alerts="$(tmux display-message -p -t "${session_id}" '#{session_alerts}' 2>/dev/null || true)"

count=0
if [[ -n "${alerts}" ]]; then
  declare -A seen=()
  IFS=',' read -r -a parts <<<"${alerts}"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    part="${part%%[^0-9]*}"
    [[ -z "${part}" ]] && continue
    if [[ -z "${seen[$part]+x}" ]]; then
      seen[$part]=1
      count=$((count + 1))
    fi
  done
else
  while IFS=$'\t' read -r activity bell silence; do
    if [[ "${activity}" == "1" || "${bell}" == "1" || "${silence}" == "1" ]]; then
      count=$((count + 1))
    fi
  done < <(tmux list-windows -t "${session_id}" -F $'#{window_activity_flag}\t#{window_bell_flag}\t#{window_silence_flag}' 2>/dev/null || true)
fi

if (( count > 0 )); then
  printf '#[fg=colour208,bold]●%d#[default]' "${count}"
fi
