#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

open_pipe() {
  local pane_id="${1:-}"
  [[ -n "${pane_id}" ]] || return 0
  local pane_id_strftime_safe="${pane_id/#%/%%}"
  tmux pipe-pane -t "${pane_id}" "bash ~/.config/tmux/scripts/pane_output_watch.sh ${pane_id_strftime_safe}" >/dev/null 2>&1 || true
}

install_one() {
  local pane_id="${1:-}"
  [[ -n "${pane_id}" ]] || return 0
  local has_pipe
  has_pipe="$(tmux display-message -p -t "${pane_id}" '#{pane_pipe}' 2>/dev/null || echo 0)"
  if [[ "${has_pipe:-0}" == "1" ]]; then
    return 0
  fi
  open_pipe "${pane_id}"
}

force_one() {
  local pane_id="${1:-}"
  [[ -n "${pane_id}" ]] || return 0
  tmux pipe-pane -t "${pane_id}" >/dev/null 2>&1 || true
  local pane_id_strftime_safe="${pane_id/#%/%%}"
  tmux pipe-pane -t "${pane_id}" "bash ~/.config/tmux/scripts/pane_output_watch.sh ${pane_id_strftime_safe}" >/dev/null 2>&1 || true
}

install_all() {
  local pane_id has_pipe
  while IFS=$'\t' read -r pane_id has_pipe; do
    [[ -n "${pane_id}" ]] || continue
    [[ "${has_pipe:-0}" == "1" ]] && continue
    open_pipe "${pane_id}"
  done < <(tmux list-panes -a -F $'#{pane_id}\t#{pane_pipe}' 2>/dev/null || true)
}

case "${mode}" in
  --all|"")
    install_all
    ;;
  --force-all)
    while IFS= read -r pane_id; do
      [[ -n "${pane_id}" ]] || continue
      force_one "${pane_id}"
    done < <(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || true)
    ;;
  *)
    install_one "${mode}"
    ;;
esac
