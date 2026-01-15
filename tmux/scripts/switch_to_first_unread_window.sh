#!/usr/bin/env bash
set -euo pipefail

client_tty="${1:-}"

tmux_display() {
  local fmt="${1:-}"
  if [[ -n "${client_tty}" ]]; then
    tmux display-message -p -c "${client_tty}" "${fmt}" 2>/dev/null || true
  else
    tmux display-message -p "${fmt}" 2>/dev/null || true
  fi
}

tmux_switch() {
  local target="${1:-}"
  [[ -z "${target}" ]] && return 0
  if [[ -n "${client_tty}" ]]; then
    tmux switch-client -c "${client_tty}" -t "${target}" 2>/dev/null || true
  else
    tmux switch-client -t "${target}" 2>/dev/null || true
  fi
}

IFS=$'\t' read -r session_id session_alerts current_window_index < <(
  tmux_display $'#{session_id}\t#{session_alerts}\t#{window_index}'
)

[[ -z "${session_id}" ]] && exit 0
[[ -z "${session_alerts}" ]] && exit 0

declare -A seen=()
min_idx=0
found=0

IFS=',' read -r -a parts <<<"${session_alerts}"
for part in "${parts[@]}"; do
  part="${part//[[:space:]]/}"
  idx="${part%%[^0-9]*}"
  [[ -z "${idx}" ]] && continue
  [[ "${idx}" =~ ^[0-9]+$ ]] || continue
  if [[ -z "${seen[$idx]+x}" ]]; then
    seen[$idx]=1
    if (( found == 0 || idx < min_idx )); then
      min_idx=$idx
      found=1
    fi
  fi
done

(( found == 0 )) && exit 0

if [[ "${current_window_index:-}" =~ ^[0-9]+$ && "${min_idx}" == "${current_window_index}" ]]; then
  exit 0
fi

tmux_switch "${session_id}:${min_idx}"
