#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
client_tty="${2:-}"
socket_path="${3:-}"
lock_dir="${TMPDIR:-/tmp}/codex-tmux-progress-click-${target}-${client_tty//[^A-Za-z0-9_.-]/_}"
log_file="${HOME}/.config/tmux/run/codex-progress-click.log"

log_click() {
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0
  {
    printf '%s target=%s tty=%s socket=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$target" "$client_tty" "$socket_path" "$*"
  } >>"$log_file" 2>/dev/null || return 0
  if tail -n 40 "$log_file" >"${log_file}.$$" 2>/dev/null; then
    mv "${log_file}.$$" "$log_file" 2>/dev/null || true
  else
    rm -f "${log_file}.$$" 2>/dev/null || true
  fi
}

case "$target" in
  running)
    target_state="in_progress"
    ;;
  unread)
    target_state="unread"
    ;;
  attention)
    target_state="attention"
    ;;
  active)
    target_state="active"
    ;;
  *)
    log_click "ignored=unknown-target"
    exit 0
    ;;
esac

runner="${HOME}/.config/tmux/scripts/codex_tmux_progress_tmux.sh"
if [[ ! -x "$runner" ]]; then
  log_click "ignored=missing-runner"
  exit 0
fi

if ! mkdir "$lock_dir" 2>/dev/null; then
  log_click "ignored=locked"
  exit 0
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

log_click "run target_state=${target_state}"
"$runner" \
  --event tmux-jump \
  --socket "$socket_path" \
  --client-tty "$client_tty" \
  --target-state "$target_state" \
  >/dev/null 2>&1 || true
