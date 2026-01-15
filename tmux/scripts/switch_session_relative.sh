#!/usr/bin/env bash
set -euo pipefail

direction="${1:-}"
client="${2:-}"

if [[ "${direction}" != "left" && "${direction}" != "right" ]]; then
  exit 0
fi

current_session_name="$(
  if [[ -n "${client}" ]]; then
    tmux display-message -p -c "${client}" "#{client_session}" 2>/dev/null || true
  else
    tmux display-message -p "#{session_name}" 2>/dev/null || true
  fi
)"

if [[ -z "${current_session_name}" || ! "${current_session_name}" =~ ^([0-9]+)- ]]; then
  exit 0
fi
current_index="${BASH_REMATCH[1]}"

max_index="$(
  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | awk -F '-' '$1 ~ /^[0-9]+$/ { if ($1 + 0 > m) m = $1 + 0 } END { print m + 0 }'
)"

if [[ -z "${max_index}" || ! "${max_index}" =~ ^[0-9]+$ || "${max_index}" -le 0 ]]; then
  exit 0
fi

target_index="${current_index}"
if [[ "${direction}" == "left" ]]; then
  if (( target_index <= 0 )); then
    target_index="${max_index}"
  else
    target_index="$(( target_index - 1 ))"
  fi
else
  if (( target_index >= max_index )); then
    target_index="0"
  else
    target_index="$(( target_index + 1 ))"
  fi
fi

bash "${HOME}/.config/tmux/scripts/switch_session_by_index.sh" "${target_index}" "${client}"
