#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
pane_id="${2:-}"

state_dir="${TMUX_PANE_UNREAD_DIR:-$HOME/.config/tmux/run/pane-unread}"
window_state_dir="${TMUX_WINDOW_ACTIVE_PANE_DIR:-$HOME/.config/tmux/run/window-active-pane}"
mark="${TMUX_PANE_UNREAD_MARK:-#[fg=colour208]●#[fg=colour244] }"

safe_pane_id() {
  local value="$1"
  value="${value//\//_}"
  value="${value//../__}"
  printf '%s' "$value"
}

ensure_dir() {
  mkdir -p "$state_dir"
}

safe_window_id() {
  local value="$1"
  value="${value//\//_}"
  value="${value//../__}"
  printf '%s' "$value"
}

ensure_window_dir() {
  mkdir -p "$window_state_dir"
}

case "$cmd" in
  remember-window-active)
    window_id="${pane_id:-}"
    active_pane_id="${3:-}"
    [[ -z "${window_id:-}" || -z "${active_pane_id:-}" ]] && exit 0
    ensure_window_dir
    printf '%s' "$active_pane_id" >"$window_state_dir/$(safe_window_id "$window_id")"
    ;;
  mark-window-remembered)
    window_id="${pane_id:-}"
    [[ -z "${window_id:-}" ]] && exit 0
    remembered_file="$window_state_dir/$(safe_window_id "$window_id")"
    [[ ! -f "$remembered_file" ]] && exit 0
    remembered_pane_id=$(cat "$remembered_file" 2>/dev/null || true)
    [[ -z "${remembered_pane_id:-}" ]] && exit 0
    ensure_dir
    touch "$state_dir/$(safe_pane_id "$remembered_pane_id")"
    ;;
  mark-window-active)
    window_id="${pane_id:-}"
    [[ -z "${window_id:-}" ]] && exit 0
    active_pane_id=$(
      tmux list-panes -t "$window_id" -F '#{pane_active}:#{pane_id}' 2>/dev/null | awk -F':' '$1 == 1 { print $2; exit }'
    )
    [[ -z "${active_pane_id:-}" ]] && exit 0
    ensure_dir
    touch "$state_dir/$(safe_pane_id "$active_pane_id")"
    ;;
  mark)
    [[ -z "${pane_id:-}" ]] && exit 0
    ensure_dir
    touch "$state_dir/$(safe_pane_id "$pane_id")"
    ;;
  clear)
    [[ -z "${pane_id:-}" ]] && exit 0
    rm -f "$state_dir/$(safe_pane_id "$pane_id")"
    ;;
  indicator)
    [[ -z "${pane_id:-}" ]] && exit 0
    if [[ -f "$state_dir/$(safe_pane_id "$pane_id")" ]]; then
      printf '%s' "$mark"
    fi
    ;;
  *)
    exit 0
    ;;
esac
