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

IFS=$'\t' read -r session_id current_window_index < <(
  tmux_display $'#{session_id}\t#{window_index}'
)

[[ -z "${session_id}" ]] && exit 0

min_idx="$(
  tmux list-windows -t "${session_id}" -F $'#{window_index}\t#{window_id}\t#{?#{==:#{@unread_activity},1},1,0}\t#{window_activity_flag}\t#{window_bell_flag}\t#{window_silence_flag}' 2>/dev/null \
    | sort -n -k1,1 \
    | while IFS=$'\t' read -r win_index win_id custom_unread tmux_activity bell silence; do
        if [[ "${custom_unread:-0}" != "1" && "${tmux_activity:-0}" != "1" && "${bell:-0}" != "1" && "${silence:-0}" != "1" ]]; then
          continue
        fi
        if [[ "${custom_unread:-0}" != "1" && "${tmux_activity:-0}" == "1" ]]; then
          if ~/.config/tmux/scripts/window_is_ignored.sh "${win_id}" >/dev/null 2>&1; then
            continue
          fi
        fi
        printf '%s\n' "${win_index}"
        break
      done
)"

[[ -z "${min_idx:-}" ]] && exit 0

if [[ "${current_window_index:-}" =~ ^[0-9]+$ && "${min_idx}" == "${current_window_index}" ]]; then
  exit 0
fi

tmux_switch "${session_id}:${min_idx}"
