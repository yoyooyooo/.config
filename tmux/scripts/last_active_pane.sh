#!/usr/bin/env bash
set -euo pipefail

if [[ -f "$HOME/.config/tmux/scripts/lib/tmux_kit_proxy.sh" ]]; then
  # shellcheck source=$HOME/.config/tmux/scripts/lib/tmux_kit_proxy.sh
  source "$HOME/.config/tmux/scripts/lib/tmux_kit_proxy.sh"
fi

cmd="${1:-}"
shift || true

client_tty="${1:-}"
shift || true

state_dir="${TMUX_LAST_ACTIVE_PANE_DIR:-$HOME/.config/tmux/run/last-active-pane}"
dry_run="${TMUX_LAST_ACTIVE_PANE_DRY_RUN:-0}"

safe_key() {
  local value="$1"
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value//../__}"
  printf '%s' "$value"
}

state_path() {
  local key
  key="$(safe_key "${client_tty:-default}")"
  printf '%s/%s' "${state_dir}" "${key}"
}

read_state() {
  local path="$1"
  local last="" prev=""
  if [[ -f "${path}" ]]; then
    IFS=$'\t' read -r last prev <"${path}" 2>/dev/null || true
  fi
  printf '%s\t%s\n' "${last}" "${prev}"
}

write_state() {
  local path="$1"
  local last="$2"
  local prev="$3"
  mkdir -p "${state_dir}" 2>/dev/null || true
  printf '%s\t%s\n' "${last}" "${prev}" >"${path}.tmp"
  mv -f "${path}.tmp" "${path}"
}

tmux_display() {
  local fmt="${1:-}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux display-message -p -c "${client_tty}" "${fmt}" 2>/dev/null || true
  else
    tmux display-message -p "${fmt}" 2>/dev/null || true
  fi
}

jump_to_pane() {
  local pane_id="$1"
  [[ -n "${pane_id:-}" ]] || return 1

  local meta session_id window_id
  meta="$(tmux display-message -p -t "${pane_id}" $'#{session_id}\t#{window_id}' 2>/dev/null || true)"
  [[ -n "${meta:-}" ]] || return 1

  IFS=$'\t' read -r session_id window_id <<<"${meta}"
  [[ -n "${session_id:-}" ]] || return 1

  if [[ "${dry_run}" == "1" ]]; then
    printf 'action=jump client=%s pane=%s session=%s window=%s\n' "${client_tty:-default}" "${pane_id}" "${session_id}" "${window_id:-}"
    return 0
  fi

  if [[ -n "${client_tty:-}" ]]; then
    tmux switch-client -c "${client_tty}" -t "${session_id}" >/dev/null 2>&1 || tmux switch-client -c "${client_tty}" -t "${pane_id}" >/dev/null 2>&1 || true
  else
    tmux switch-client -t "${session_id}" >/dev/null 2>&1 || tmux switch-client -t "${pane_id}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${window_id:-}" ]]; then
    tmux select-window -t "${session_id}:${window_id}" >/dev/null 2>&1 || tmux select-window -t "${window_id}" >/dev/null 2>&1 || true
  fi
  tmux select-pane -t "${pane_id}" >/dev/null 2>&1 || true
  return 0
}

record() {
  local current_pane_id="${1:-}"
  [[ -n "${current_pane_id:-}" ]] || return 0

  local path last prev
  path="$(state_path)"
  IFS=$'\t' read -r last prev < <(read_state "${path}")

  [[ "${current_pane_id}" == "${last:-}" ]] && return 0
  write_state "${path}" "${current_pane_id}" "${last:-}"
  return 0
}

jump() {
  local path last prev
  path="$(state_path)"
  IFS=$'\t' read -r last prev < <(read_state "${path}")

  local current
  current="$(tmux_display '#{pane_id}')"

  if [[ -n "${prev:-}" && "${prev}" != "${current:-}" ]]; then
    if jump_to_pane "${prev}"; then
      return 0
    fi
    write_state "${path}" "${last:-}" ""
  fi

  if [[ -n "${last:-}" && "${last}" != "${current:-}" ]]; then
    jump_to_pane "${last}" || true
  fi
  return 0
}

case "${cmd}" in
  record)
    record "${1:-}"
    ;;
  jump)
    jump
    ;;
  *)
    exit 0
    ;;
esac
