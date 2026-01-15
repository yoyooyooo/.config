#!/usr/bin/env bash
set -euo pipefail

target_pane_id="${1:-}"
client_name="${2:-}"
client_pid="${3:-}"

if [[ -z "${target_pane_id}" ]]; then
  exit 0
fi

scope_key="global"
if [[ -n "${client_pid}" && "${client_pid}" =~ ^[0-9]+$ ]]; then
  scope_key="${client_pid}"
fi

armed_key="@kill_pane_double_tap_armed_${scope_key}"
pane_key="@kill_pane_double_tap_pane_${scope_key}"
token_key="@kill_pane_double_tap_token_${scope_key}"

display() {
  local msg="$1"
  if [[ -n "${client_name}" ]]; then
    tmux display-message -c "${client_name}" "${msg}" 2>/dev/null || true
  else
    tmux display-message "${msg}" 2>/dev/null || true
  fi
}

armed="$(tmux show-option -gqv "${armed_key}" 2>/dev/null || true)"
armed_pane="$(tmux show-option -gqv "${pane_key}" 2>/dev/null || true)"

if [[ "${armed}" == "1" && "${armed_pane}" == "${target_pane_id}" ]]; then
  tmux set -gu "${armed_key}" 2>/dev/null || true
  tmux set -gu "${pane_key}" 2>/dev/null || true
  tmux set -gu "${token_key}" 2>/dev/null || true
  tmux kill-pane -t "${target_pane_id}" 2>/dev/null || true
  exit 0
fi

timeout_s="$(tmux show-option -gqv @kill_pane_double_tap_timeout_s 2>/dev/null || true)"
if [[ -z "${timeout_s}" || ! "${timeout_s}" =~ ^[0-9]+$ ]]; then
  timeout_s="1"
fi

token="$(date +%s)-$$-${RANDOM}"

tmux set -g "${armed_key}" 1 2>/dev/null || true
tmux set -g "${pane_key}" "${target_pane_id}" 2>/dev/null || true
tmux set -g "${token_key}" "${token}" 2>/dev/null || true

display "再按一次确认关闭当前 pane"

(
  sleep "${timeout_s}"
  current_token="$(tmux show-option -gqv "${token_key}" 2>/dev/null || true)"
  if [[ "${current_token}" == "${token}" ]]; then
    tmux set -gu "${armed_key}" 2>/dev/null || true
    tmux set -gu "${pane_key}" 2>/dev/null || true
    tmux set -gu "${token_key}" 2>/dev/null || true
  fi
) >/dev/null 2>&1 &
