#!/usr/bin/env bash
set -euo pipefail

client_tty="${1:-}"

debounce_s="${TMUX_CODEX_SWITCH_NOTIFY_DEBOUNCE_S:-0.2}"
case "${debounce_s}" in
  0 | 0.0 | "" | false | FALSE | off | OFF | no | NO) debounce_s="0" ;;
esac

state_dir="${TMUX_CODEX_SWITCH_NOTIFY_STATE_DIR:-$HOME/.config/tmux/run/codex-switch-notify}"
turn_complete_dir="${CODEX_TMUX_TURN_COMPLETE_DIR:-$HOME/.config/tmux/run/codex-turn-complete}"
fallback_enabled="${TMUX_CODEX_DONE_FALLBACK:-0}"
fallback_state_dir="${TMUX_CODEX_DONE_FALLBACK_STATE_DIR:-$HOME/.config/tmux/run/codex-done-fallback}"

safe_key() {
  local value="$1"
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value//../__}"
  printf '%s' "$value"
}

key="$(safe_key "${client_tty:-default}")"
token="${EPOCHREALTIME:-$(date +%s)}-$$-$RANDOM"

mkdir -p "${state_dir}" 2>/dev/null || true
printf '%s' "${token}" >"${state_dir}/${key}" 2>/dev/null || true

tmux_display() {
  local fmt="${1:-}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux display-message -p -c "${client_tty}" "${fmt}" 2>/dev/null || true
  else
    tmux display-message -p "${fmt}" 2>/dev/null || true
  fi
}

if [[ "${debounce_s}" != "0" ]]; then
  sleep "${debounce_s}" 2>/dev/null || sleep 0.2
fi

last_token="$(cat "${state_dir}/${key}" 2>/dev/null || true)"
if [[ -n "${last_token:-}" && "${last_token}" != "${token}" ]]; then
  exit 0
fi

IFS=$'\t' read -r session_name window_index window_name pane_id < <(
  tmux_display $'#{session_name}\t#{window_index}\t#{window_name}\t#{pane_id}'
)

[[ -z "${pane_id:-}" ]] && exit 0

marker_path="${turn_complete_dir}/$(safe_key "${pane_id}")"

default_title="${TMUX_CODEX_DONE_NOTIFY_TITLE:-✅ 完成}"
hud_body="${session_name}:${window_index} ${window_name}"
if [[ -z "${hud_body//[[:space:]]/}" ]]; then
  hud_body="${pane_id}"
fi

delay_ms="${TMUX_CODEX_DONE_NOTIFY_TMUX_MESSAGE_DELAY_MS:-1200}"
if [[ -z "${delay_ms:-}" || ! "${delay_ms}" =~ ^[0-9]+$ ]]; then
  delay_ms=1200
fi

maybe_fallback_notify() {
  [[ "${fallback_enabled}" == "1" ]] || return 0

  local current_cmd
  current_cmd="$(tmux display-message -p -t "${pane_id}" '#{pane_current_command}' 2>/dev/null || true)"
  case "${current_cmd}" in
    codex | codex-cli | codex-rs) ;;
    *) return 0 ;;
  esac

  local lines="${TMUX_CODEX_DONE_FALLBACK_CAPTURE_LINES:-120}"
  if [[ -z "${lines:-}" || ! "${lines}" =~ ^[0-9]+$ ]]; then
    lines=120
  fi

  local snapshot
  snapshot="$(tmux capture-pane -p -t "${pane_id}" -S "-${lines}" 2>/dev/null || true)"
  [[ -n "${snapshot:-}" ]] || return 0

  local key="to interrupt"
  if printf '%s' "${snapshot}" | grep -qiF -- "${key}"; then
    rm -f "${fallback_state_dir}/$(safe_key "${pane_id}")" 2>/dev/null || true
    return 0
  fi

  mkdir -p "${fallback_state_dir}" 2>/dev/null || true
  local seen="${fallback_state_dir}/$(safe_key "${pane_id}")"
  [[ -f "${seen}" ]] && return 0
  printf '%s' "$(date +%s)" >"${seen}" 2>/dev/null || true

  local hud_title="${TMUX_CODEX_DONE_FALLBACK_NOTIFY_TITLE:-✅ 完成（推断）}"
  if ~/.config/tmux/scripts/tmux_btt_hud_notify.sh "${hud_title}" "${hud_body}" "${client_tty:-}" 2>/dev/null; then
    return 0
  fi

  local msg="${hud_title} ${hud_body}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux display-message -c "${client_tty}" -d "${delay_ms}" -N "${msg}" 2>/dev/null || true
  else
    tmux display-message -d "${delay_ms}" -N "${msg}" 2>/dev/null || true
  fi
  return 0
}

if [[ ! -f "${marker_path}" ]]; then
  maybe_fallback_notify
  exit 0
fi

~/.config/tmux/extensions/codex/scripts/codex_notify_ack_turn_complete.sh "${pane_id}" >/dev/null 2>&1 || true

if ~/.config/tmux/scripts/tmux_btt_hud_notify.sh "${default_title}" "${hud_body}" "${client_tty:-}" 2>/dev/null; then
  exit 0
fi

msg="${default_title} ${hud_body}"
if [[ -n "${client_tty:-}" ]]; then
  tmux display-message -c "${client_tty}" -d "${delay_ms}" -N "${msg}" 2>/dev/null || true
else
  tmux display-message -d "${delay_ms}" -N "${msg}" 2>/dev/null || true
fi
