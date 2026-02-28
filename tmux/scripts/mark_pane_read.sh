#!/usr/bin/env bash
set -euo pipefail

pane_id="${1:-}"
window_id="${2:-}"

suppress_seconds="${TMUX_UNREAD_SUPPRESS_AFTER_READ_SECONDS:-2}"
if [[ -z "${suppress_seconds}" || ! "${suppress_seconds}" =~ ^[0-9]+$ ]]; then
  suppress_seconds=2
fi

pane_exists=0
if [[ -n "${pane_id}" ]]; then
  pane_check="$(tmux display-message -p -t "${pane_id}" '#{pane_id}' 2>/dev/null || true)"
  if [[ -n "${pane_check}" ]]; then
    pane_exists=1
  fi
fi

if [[ -z "${window_id}" && "${pane_exists}" == "1" ]]; then
  window_id="$(tmux display-message -p -t "${pane_id}" '#{window_id}' 2>/dev/null || true)"
fi

now_s="$(date +%s 2>/dev/null || echo 0)"
if [[ -z "${now_s:-}" || ! "${now_s}" =~ ^[0-9]+$ ]]; then
  now_s=0
fi
suppress_until="$((now_s + suppress_seconds))"

if [[ "${pane_exists}" == "1" ]]; then
  tmux set -p -t "${pane_id}" @unread_pane_activity 0 >/dev/null 2>&1 || true
  tmux set -p -t "${pane_id}" @unread_ignore_activity 0 >/dev/null 2>&1 || true
  tmux set -p -t "${pane_id}" @unread_ignore_checked 0 >/dev/null 2>&1 || true
  tmux set -p -t "${pane_id}" @unread_ignore_check_count 0 >/dev/null 2>&1 || true
  tmux set -p -t "${pane_id}" @unread_ignore_checked_at "${now_s}" >/dev/null 2>&1 || true
  tmux set -p -t "${pane_id}" @unread_suppress_until "${suppress_until}" >/dev/null 2>&1 || true
fi

if [[ -n "${window_id}" ]]; then
  ~/.config/tmux/scripts/sync_window_unread_activity.sh "${window_id}" "${pane_id}" >/dev/null 2>&1 || true
elif [[ "${pane_exists}" == "1" ]]; then
  ~/.config/tmux/scripts/sync_window_unread_activity.sh "" "${pane_id}" >/dev/null 2>&1 || true
fi

