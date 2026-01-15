#!/usr/bin/env bash
set -euo pipefail

target_pane_id="${1:-}"
if [[ -z "${target_pane_id}" ]]; then
  target_pane_id="${2:-}"
fi
if [[ -z "${target_pane_id}" ]]; then
  exit 0
fi

threshold="$(tmux show-option -gqv @copy_mode_auto_cancel_threshold 2>/dev/null || true)"
if [[ -z "${threshold}" ]]; then
  threshold="20"
fi

if [[ ! "${threshold}" =~ ^[0-9]+$ ]]; then
  threshold="20"
fi

pane_mode="$(tmux display-message -p -t "${target_pane_id}" "#{pane_mode}" 2>/dev/null || true)"
if [[ "${pane_mode}" != copy-mode* ]]; then
  exit 0
fi

scroll_position="$(tmux display-message -p -t "${target_pane_id}" "#{scroll_position}" 2>/dev/null || true)"
if [[ -z "${scroll_position}" ]]; then
  exit 0
fi
if [[ ! "${scroll_position}" =~ ^[0-9]+$ ]]; then
  exit 0
fi

if (( scroll_position <= threshold )); then
  tmux send-keys -t "${target_pane_id}" -X cancel
fi
