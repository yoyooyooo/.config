#!/usr/bin/env bash
set -euo pipefail

window_id="${1:-}"
[[ -n "${window_id}" ]] || exit 0

seq="$(tmux show -gqv @next_unread_seq 2>/dev/null || true)"
if [[ -z "${seq:-}" || ! "${seq}" =~ ^[0-9]+$ ]]; then
  seq=0
fi
seq=$((seq + 1))

tmux set -g @next_unread_seq "${seq}" 2>/dev/null || true
tmux set -w -t "${window_id}" @next_unread_seen_seq "${seq}" 2>/dev/null || true
