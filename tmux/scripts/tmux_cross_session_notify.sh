#!/usr/bin/env bash
set -euo pipefail

from_session="${1:-}"
to_session="${2:-}"
to_window="${3:-}"
client_tty="${4:-}"

message="跨会话：${from_session} → ${to_session}"
if [[ -n "${to_window:-}" ]]; then
  message="${message}（#${to_window}）"
fi

btt_trigger="$(tmux show -gqv @tmux_cross_session_btt_hud_trigger 2>/dev/null || true)"
btt_title_var="$(tmux show -gqv @tmux_cross_session_btt_hud_title_var 2>/dev/null || true)"
btt_body_var="$(tmux show -gqv @tmux_cross_session_btt_hud_body_var 2>/dev/null || true)"

if [[ -z "${btt_trigger:-}" ]]; then
  btt_trigger="btt-hud-overlay"
fi
if [[ -z "${btt_title_var:-}" ]]; then
  btt_title_var="hud_title"
fi
if [[ -z "${btt_body_var:-}" ]]; then
  btt_body_var="hud_body"
fi

case "${btt_trigger}" in
  0|false|FALSE|off|OFF|no|NO)
    btt_trigger=""
    ;;
esac

try_btt=0
if [[ -n "${btt_trigger:-}" ]]; then
  try_btt=1
fi

btt_ok=0
if (( try_btt == 1 )); then
  hud_title='跨会话切换'
  hud_body="${from_session} → ${to_session}"
  if [[ -n "${to_window:-}" ]]; then
    hud_body="${hud_body}（#${to_window}）"
  fi

  if ~/.config/tmux/scripts/tmux_btt_hud_notify.sh "$hud_title" "$hud_body" "${client_tty:-}" 2>/dev/null; then
    btt_ok=1
  fi
fi

show_tmux_message="$(tmux show -gqv @tmux_cross_session_show_tmux_message 2>/dev/null || true)"
case "${show_tmux_message}" in
  1|true|TRUE|on|ON|yes|YES) show_tmux_message="1" ;;
  0|false|FALSE|off|OFF|no|NO) show_tmux_message="0" ;;
  *) show_tmux_message="" ;;
esac

if [[ -z "${show_tmux_message:-}" ]]; then
  # Default: if HUD is enabled, don't cover the window list; otherwise fall back to tmux message.
  if (( btt_ok == 1 )); then
    show_tmux_message="0"
  else
    show_tmux_message="1"
  fi
fi

if [[ "${show_tmux_message}" == "1" ]]; then
  delay_ms="$(tmux show -gqv @tmux_cross_session_tmux_message_delay_ms 2>/dev/null || true)"
  if [[ -z "${delay_ms:-}" || ! "${delay_ms}" =~ ^[0-9]+$ ]]; then
    delay_ms=800
  fi

  if [[ -n "${client_tty:-}" ]]; then
    tmux display-message -c "${client_tty}" -d "${delay_ms}" -N "$message" 2>/dev/null || true
  else
    tmux display-message -d "${delay_ms}" -N "$message" 2>/dev/null || true
  fi
fi
