#!/usr/bin/env bash
set -euo pipefail

# Ensure client context is stable in multi-client setups.
client_tty="${1:-}"

# Switch between "unread" windows (alerts) with low overhead:
# 1) If current session has alerts -> next alert window in this session
# 2) Otherwise -> switch to the next session (by N- prefix order) that has alerts

dry_run="${TMUX_NEXT_UNREAD_DRY_RUN:-0}"
force_cross="${TMUX_NEXT_UNREAD_FORCE_CROSS:-0}"
exclude_session_substr="${TMUX_NEXT_UNREAD_EXCLUDE_SESSION_SUBSTR:-后台}"
prioritize_codex_done="${TMUX_NEXT_UNREAD_PRIORITIZE_CODEX_DONE:-1}"
codex_turn_complete_dir="${CODEX_TMUX_TURN_COMPLETE_DIR:-$HOME/.config/tmux/run/codex-turn-complete}"

tmux_display() {
  local fmt="${1:-}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux display-message -p -c "${client_tty}" "${fmt}"
  else
    tmux display-message -p "${fmt}"
  fi
}

tmux_switch() {
  local target="${1:-}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux switch-client -c "${client_tty}" -t "${target}"
  else
    tmux switch-client -t "${target}"
  fi
}

maybe_notify_codex_done() {
  [[ "${TMUX_ENABLE_CODEX:-0}" == "1" ]] || return 0
  local script=""
  if [[ -x "$HOME/.config/tmux/extensions/codex/scripts/codex_notify_on_switch_done.sh" ]]; then
    script="$HOME/.config/tmux/extensions/codex/scripts/codex_notify_on_switch_done.sh"
  elif [[ -x "$HOME/.config/tmux/local/scripts/codex_notify_on_switch_done.sh" ]]; then
    script="$HOME/.config/tmux/local/scripts/codex_notify_on_switch_done.sh"
  elif [[ -x "$HOME/.config/tmux/scripts/codex_notify_on_switch_done.sh" ]]; then
    script="$HOME/.config/tmux/scripts/codex_notify_on_switch_done.sh"
  fi
  [[ -n "${script}" ]] || return 0
  ("${script}" "${client_tty:-}" >/dev/null 2>&1 || true) &
}

maybe_jump_latest_codex_done() {
  [[ "${prioritize_codex_done}" == "1" ]] || return 0
  [[ -d "${codex_turn_complete_dir}" ]] || return 0

  local -a markers
  mapfile -t markers < <(ls -t "${codex_turn_complete_dir}" 2>/dev/null || true)
  (( ${#markers[@]} > 0 )) || return 0

  local current_session_id marker pane_id meta session_id window_index pass action
  current_session_id="$(tmux_display '#{session_id}' 2>/dev/null || true)"
  for pass in current any; do
    if [[ "${pass}" == "current" && -z "${current_session_id:-}" ]]; then
      continue
    fi
    action="codex"
    if [[ "${pass}" == "current" ]]; then
      action="codex_current"
    fi

    for marker in "${markers[@]}"; do
      [[ -n "${marker:-}" ]] || continue
      pane_id="${marker}"
      [[ "${pane_id}" =~ ^%[0-9]+$ ]] || continue

      meta="$(tmux display-message -p -t "${pane_id}" $'#{session_id}\t#{window_index}' 2>/dev/null || true)"
      if [[ -z "${meta:-}" ]]; then
        rm -f "${codex_turn_complete_dir}/${marker}" 2>/dev/null || true
        continue
      fi

      IFS=$'\t' read -r session_id window_index <<<"${meta}"
      [[ -n "${session_id:-}" && -n "${window_index:-}" ]] || continue

      if [[ "${pass}" == "current" && "${session_id}" != "${current_session_id}" ]]; then
        continue
      fi

      if [[ "${dry_run}" == "1" ]]; then
        printf 'action=%s pane=%s -> %s:%s\n' "${action}" "${pane_id}" "${session_id}" "${window_index}"
        exit 0
      fi

      tmux_switch "${session_id}:${window_index}"
      tmux select-pane -t "${pane_id}" 2>/dev/null || true
      maybe_notify_codex_done
      exit 0
    done
  done

  return 0
}

tmux_message() {
  local msg="${1:-}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux display-message -c "${client_tty}" "${msg}"
  else
    tmux display-message "${msg}"
  fi
}

session_is_excluded() {
  local session_name="${1:-}"
  [[ -z "${exclude_session_substr}" ]] && return 1

  local token
  local IFS=',，'
  for token in ${exclude_session_substr}; do
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -z "${token}" ]] && continue
    [[ "${session_name}" == *"${token}"* ]] && return 0
  done

  return 1
}

sorted_alert_windows() {
  local alerts="${1:-}"
  [[ -z "${alerts:-}" ]] && return 0

  local -a entries
  local entry
  IFS=',' read -r -a entries <<<"${alerts}"
  for entry in "${entries[@]}"; do
    entry="${entry//[[:space:]]/}"
    entry="${entry%%[^0-9]*}"
    [[ -n "${entry:-}" ]] && printf '%s\n' "${entry}"
  done | sort -n -u
}

fallback_alert_windows_from_list_windows() {
  local session_id="${1:-}"
  [[ -z "${session_id:-}" ]] && return 0

  tmux list-windows -t "${session_id}" -F $'#{window_index}\t#{window_activity_flag}\t#{window_bell_flag}' 2>/dev/null |
    while IFS=$'\t' read -r idx activity bell; do
      if [[ "${activity:-}" == "1" || "${bell:-}" == "1" ]]; then
        printf '%s\n' "${idx}"
      fi
    done | sort -n -u
}

choose_next_alert_window() {
  local current="${1:-0}"
  shift || true

  local first=""
  local w
  for w in "$@"; do
    [[ -z "${first:-}" ]] && first="${w}"
    if [[ "${w}" =~ ^[0-9]+$ ]] && (( w > current )); then
      printf '%s' "${w}"
      return 0
    fi
  done
  [[ -n "${first:-}" ]] && printf '%s' "${first}"
}

maybe_jump_latest_codex_done

current_session_id=$(tmux_display '#{session_id}' 2>/dev/null || true)
current_session_name=$(tmux_display '#{session_name}' 2>/dev/null || true)
current_alerts=$(tmux_display '#{session_alerts}' 2>/dev/null || true)
current_window_index=$(tmux_display '#{window_index}' 2>/dev/null || true)
current_window_index="${current_window_index:-0}"
if [[ ! "${current_window_index}" =~ ^[0-9]+$ ]]; then
  current_window_index=0
fi

current_session_excluded=0
if session_is_excluded "${current_session_name:-}"; then
  current_session_excluded=1
fi

if [[ "${force_cross}" != "1" && -n "${current_alerts:-}" && "${current_session_excluded}" != "1" ]]; then
  readarray -t alert_windows < <(sorted_alert_windows "${current_alerts}")
  if (( ${#alert_windows[@]} == 0 )); then
    readarray -t alert_windows < <(fallback_alert_windows_from_list_windows "${current_session_id}")
  fi
  if (( ${#alert_windows[@]} > 0 )); then
    target_window="$(choose_next_alert_window "${current_window_index}" "${alert_windows[@]}")"
    if [[ -n "${target_window:-}" ]]; then
      if [[ "${dry_run}" == "1" ]]; then
        printf 'action=in_session current=%s(%s) window=%s alerts=%s -> %s\n' "$current_session_name" "$current_session_id" "$current_window_index" "$current_alerts" "$target_window"
        exit 0
      fi
      tmux_switch "${current_session_id}:${target_window}"
      maybe_notify_codex_done
      exit 0
    fi
  fi

  if [[ "${dry_run}" == "1" ]]; then
    printf 'action=in_session current=%s(%s) alerts=%s\n' "$current_session_name" "$current_session_id" "$current_alerts"
    exit 0
  fi
  tmux_message '未读窗口解析失败'
  exit 0
fi

current_index=0
if [[ "${current_session_name:-}" =~ ^([0-9]+)- ]]; then
  current_index="${BASH_REMATCH[1]}"
fi

best_after_idx=2147483647
best_after_id=""
best_after_alert=""

best_any_idx=2147483647
best_any_id=""
best_any_alert=""

while IFS=$'\t' read -r session_id session_name session_alerts; do
  [[ -z "${session_id:-}" ]] && continue
  [[ -z "${session_alerts:-}" ]] && continue
  [[ "${session_id:-}" == "${current_session_id:-}" ]] && continue
  session_is_excluded "${session_name:-}" && continue

  idx=1000000
  if [[ "${session_name:-}" =~ ^([0-9]+)- ]]; then
    idx="${BASH_REMATCH[1]}"
  fi

  first_alert="${session_alerts%%,*}"
  first_alert="${first_alert%% *}"
  # session_alerts entries may look like "6#,12#" (window index + flags). Keep leading digits only.
  first_alert="${first_alert%%[^0-9]*}"
  if [[ -z "${first_alert:-}" ]]; then
    continue
  fi

  if (( idx < best_any_idx )); then
    best_any_idx="$idx"
    best_any_id="$session_id"
    best_any_alert="$first_alert"
  fi

  if (( idx > current_index && idx < best_after_idx )); then
    best_after_idx="$idx"
    best_after_id="$session_id"
    best_after_alert="$first_alert"
  fi
done < <(tmux list-sessions -F $'#{session_id}\t#{session_name}\t#{session_alerts}' 2>/dev/null || true)

target_id=""
target_alert=""
if [[ -n "${best_after_id:-}" ]]; then
  target_id="$best_after_id"
  target_alert="$best_after_alert"
elif [[ -n "${best_any_id:-}" ]]; then
  target_id="$best_any_id"
  target_alert="$best_any_alert"
fi

if [[ -z "${target_id:-}" || -z "${target_alert:-}" ]]; then
  if [[ "${dry_run}" == "1" ]]; then
    printf 'action=none current=%s(%s)\n' "$current_session_name" "$current_session_id"
    exit 0
  fi
  hud_title='无未读窗口'
  hud_body=""
  if [[ -n "${current_session_name:-}" ]]; then
    hud_body="当前会话：${current_session_name}"
  fi
  if ~/.config/tmux/scripts/tmux_btt_hud_notify.sh "$hud_title" "$hud_body" "${client_tty:-}" 2>/dev/null; then
    exit 0
  fi
  tmux_message '无未读窗口'
  exit 0
fi

if [[ "${dry_run}" == "1" ]]; then
  printf 'action=cross current=%s(%s) -> %s:%s\n' "$current_session_name" "$current_session_id" "$target_id" "$target_alert"
  exit 0
fi

target_session_name=$(
  tmux list-sessions -F $'#{session_id}\t#{session_name}' 2>/dev/null | awk -F'\t' -v id="$target_id" '$1 == id { print $2; exit }'
)
if [[ -z "${target_session_name:-}" ]]; then
  target_session_name="$target_id"
fi

tmux_switch "${target_id}:${target_alert}"
if [[ -n "${current_session_name:-}" ]]; then
  ~/.config/tmux/scripts/tmux_cross_session_notify.sh "$current_session_name" "$target_session_name" "$target_alert" "${client_tty:-}" || true
fi
maybe_notify_codex_done
