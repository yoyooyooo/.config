#!/usr/bin/env bash
set -euo pipefail

# Ensure client context is stable in multi-client setups.
client_tty="${1:-}"

# Switch between "unread" windows (alerts) across sessions.
# For noisy TUIs that keep producing activity flags, prefer the least-recently-seen
# unread window (tracked via window option @next_unread_seen_seq updated by hook).

dry_run="${TMUX_NEXT_UNREAD_DRY_RUN:-0}"
force_cross="${TMUX_NEXT_UNREAD_FORCE_CROSS:-0}"
exclude_session_substr="${TMUX_NEXT_UNREAD_EXCLUDE_SESSION_SUBSTR:-后台}"

state_dir="${TMUX_NEXT_UNREAD_STATE_DIR:-$HOME/.config/tmux/run/next-unread}"
prioritize_codex_done="${TMUX_NEXT_UNREAD_PRIORITIZE_CODEX_DONE:-1}"
turn_complete_dir="${CODEX_TMUX_TURN_COMPLETE_DIR:-$HOME/.config/tmux/run/codex-turn-complete}"
debug_flag="${TMUX_NEXT_UNREAD_DEBUG:-}"
prioritize_current_panes_flag="${TMUX_NEXT_UNREAD_PRIORITIZE_CURRENT_PANES:-}"

safe_key() {
  local value="$1"
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value//../__}"
  printf '%s' "$value"
}

debug_enabled=0
if [[ -z "${debug_flag:-}" ]]; then
  debug_flag="$(tmux show -gqv @next_unread_debug 2>/dev/null || true)"
fi
case "${debug_flag:-}" in
  1|true|TRUE|on|ON|yes|YES) debug_enabled=1 ;;
esac

prioritize_current_panes_enabled=0
if [[ -z "${prioritize_current_panes_flag:-}" ]]; then
  prioritize_current_panes_flag="$(tmux show -gqv @next_unread_prioritize_current_panes 2>/dev/null || true)"
fi
case "${prioritize_current_panes_flag:-}" in
  1|true|TRUE|on|ON|yes|YES) prioritize_current_panes_enabled=1 ;;
esac

debug_log_path="${TMUX_NEXT_UNREAD_DEBUG_LOG_PATH:-}"
if [[ -z "${debug_log_path:-}" ]]; then
  debug_key="$(safe_key "${client_tty:-default}")"
  debug_log_path="${state_dir}/debug.${debug_key}.log"
fi

debug_log() {
  [[ "${debug_enabled}" == "1" ]] || return 0
  mkdir -p "${state_dir}" 2>/dev/null || true
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  printf '%s\t%s\n' "${now:-}" "${1:-}" >>"${debug_log_path}" 2>/dev/null || true
}

acquire_lock() {
  mkdir -p "${state_dir}" 2>/dev/null || true
  local key
  key="$(safe_key "${client_tty:-default}")"
  local lock_dir="${state_dir}/lock.${key}"
  if ! mkdir "${lock_dir}" 2>/dev/null; then
    return 1
  fi
  trap 'rmdir "'"${lock_dir}"'" 2>/dev/null || true' EXIT
  return 0
}

tmux_switch() {
  local target="${1:-}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux switch-client -c "${client_tty}" -t "${target}" 2>/dev/null || tmux switch-client -t "${target}" 2>/dev/null
  else
    tmux switch-client -t "${target}" 2>/dev/null
  fi
}

tmux_select_pane() {
  local target="${1:-}"
  [[ -n "${target:-}" ]] || return 0
  if [[ -n "${client_tty:-}" ]]; then
    tmux select-pane -c "${client_tty}" -t "${target}"
  else
    tmux select-pane -t "${target}"
  fi
}

tmux_message() {
  local msg="${1:-}"
  if [[ -n "${client_tty:-}" ]]; then
    tmux display-message -c "${client_tty}" "${msg}"
  else
    tmux display-message "${msg}"
  fi
}

first_unread_pane_in_window() {
  local window_id="${1:-}"
  local exclude_pane_id="${2:-}"
  [[ -n "${window_id:-}" ]] || return 0

  tmux list-panes -t "${window_id}" -F $'#{pane_id}\t#{pane_index}\t#{?#{==:#{@unread_pane_activity},1},1,0}' 2>/dev/null \
    | awk -F $'\t' -v exclude="${exclude_pane_id:-}" '
        $3 == 1 && $1 != exclude {
          print $1
          exit
        }
      ' || true
}

list_codex_done_pane_ids() {
  [[ -d "${turn_complete_dir}" ]] || return 0

  if command -v python3 >/dev/null 2>&1; then
    python3 - "${turn_complete_dir}" 2>/dev/null <<'PY' || true
import json
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else ""
if not root or not os.path.isdir(root):
    raise SystemExit(0)

items = []
for name in os.listdir(root):
    if not name or name.startswith("."):
        continue
    path = os.path.join(root, name)
    if not os.path.isfile(path):
        continue
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = None
    pane_id = None
    created = 0
    if isinstance(data, dict):
        pane_id = data.get("pane-id")
        created = data.get("created-at") if isinstance(data.get("created-at"), int) else 0
    if not isinstance(pane_id, str) or not pane_id.strip():
        pane_id = name
    pane_id = pane_id.strip()
    if not pane_id.startswith("%"):
        continue
    if created <= 0:
        try:
            created = int(os.stat(path).st_mtime)
        except OSError:
            created = 0
    items.append((created, pane_id))

items.sort(key=lambda t: (t[0], t[1]), reverse=True)
for _created, pane_id in items:
    sys.stdout.write(pane_id + "\n")
PY
    return 0
  fi

  # Fallback: best-effort by mtime.
  local path
  for path in "${turn_complete_dir}"/%*; do
    [[ -f "${path}" ]] || continue
    printf '%s\n' "${path##*/}"
  done
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

current_session_id=""
current_session_name=""
current_window_id=""
current_window_index=""
current_pane_id=""
if [[ -n "${client_tty:-}" ]]; then
  IFS=$'\t' read -r current_session_id current_session_name current_window_id current_window_index current_pane_id < <(
    tmux list-clients -F $'#{client_tty}\t#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{pane_id}' 2>/dev/null \
      | awk -F $'\t' -v tty="${client_tty}" '$1 == tty { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6; exit }'
  )
fi
if [[ -z "${current_session_name:-}" ]]; then
  IFS=$'\t' read -r current_session_id current_session_name current_window_id current_window_index current_pane_id < <(
    tmux display-message -p $'#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{pane_id}' 2>/dev/null || echo ""
  )
fi

if ! acquire_lock; then
  debug_log "action=lock_busy client_tty=${client_tty:-} current=${current_session_name:-}(${current_session_id:-}) window=${current_window_index:-} pane=${current_pane_id:-}"
  exit 0
fi

debug_log "action=invoked client_tty=${client_tty:-} current=${current_session_name:-}(${current_session_id:-}) window=${current_window_index:-} pane=${current_pane_id:-}"

if [[ "${dry_run}" != "1" && -n "${current_window_id:-}" ]]; then
  ~/.config/tmux/scripts/record_window_seen.sh "${current_window_id}" >/dev/null 2>&1 || true
fi

if [[ "${prioritize_codex_done}" != "0" && "${prioritize_codex_done}" != "false" && "${prioritize_codex_done}" != "FALSE" && "${prioritize_codex_done}" != "off" && "${prioritize_codex_done}" != "OFF" && "${prioritize_codex_done}" != "no" && "${prioritize_codex_done}" != "NO" ]]; then
  while IFS= read -r candidate_pane_id; do
    [[ -n "${candidate_pane_id:-}" ]] || continue

    IFS=$'\t' read -r cand_sess_id cand_sess_name cand_win_id cand_win_index < <(
      tmux display-message -p -t "${candidate_pane_id}" $'#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}' 2>/dev/null || true
    )
    [[ -n "${cand_sess_id:-}" ]] || continue
    [[ -n "${cand_win_index:-}" ]] || continue
    session_is_excluded "${cand_sess_name:-}" && continue

    if [[ "${dry_run}" == "1" ]]; then
      debug_log "action=codex_dry_run from=${current_session_name:-}(${current_session_id:-}) to=${cand_sess_name:-}(${cand_sess_id:-}):${cand_win_index:-} pane=${candidate_pane_id:-}"
      printf 'action=codex current=%s(%s) -> %s:%s pane=%s window=%s\n' "$current_session_name" "$current_session_id" "$cand_sess_id" "$cand_win_index" "$candidate_pane_id" "${cand_win_id:-}"
      exit 0
    fi

    if [[ -n "${cand_win_id:-}" ]]; then
      ~/.config/tmux/scripts/record_window_seen.sh "${cand_win_id}" >/dev/null 2>&1 || true
    fi

    debug_log "action=codex from=${current_session_name:-}(${current_session_id:-}) to=${cand_sess_name:-}(${cand_sess_id:-}):${cand_win_index:-} pane=${candidate_pane_id:-}"
    tmux_switch "${cand_sess_id}:${cand_win_index}" || {
      debug_log "action=codex_switch_failed to=${cand_sess_id:-}:${cand_win_index:-}"
      tmux_message "M-Tab: 切换失败（codex ${cand_sess_name:-}:${cand_win_index:-}）"
      exit 0
    }
    tmux_select_pane "${candidate_pane_id}" >/dev/null 2>&1 || true
    exit 0
  done < <(list_codex_done_pane_ids)
fi

if [[ "${prioritize_current_panes_enabled}" == "1" && -n "${current_window_id:-}" ]]; then
  unread_pane_in_current="$(first_unread_pane_in_window "${current_window_id}" "${current_pane_id:-}")"
  if [[ -n "${unread_pane_in_current:-}" ]]; then
    if [[ "${dry_run}" == "1" ]]; then
      debug_log "action=current_pane_dry_run from=${current_session_name:-}(${current_session_id:-}) window=${current_window_index:-} pane=${unread_pane_in_current:-}"
      printf 'action=current-pane current=%s(%s) -> %s window=%s\n' "$current_session_name" "$current_session_id" "$unread_pane_in_current" "$current_window_id"
      exit 0
    fi
    debug_log "action=current_pane from=${current_session_name:-}(${current_session_id:-}) window=${current_window_index:-} pane=${unread_pane_in_current:-}"
    tmux_select_pane "${unread_pane_in_current}" >/dev/null 2>&1 || true
    exit 0
  fi
fi

best_any_seen=9223372036854775807
best_any_sess_idx=2147483647
best_any_win_idx=2147483647
best_any_sess_id=""
best_any_sess_name=""
best_any_win_index=""
best_any_win_id=""
best_any_has_unread=0

best_cross_seen=9223372036854775807
best_cross_sess_idx=2147483647
best_cross_win_idx=2147483647
best_cross_sess_id=""
best_cross_sess_name=""
best_cross_win_index=""
best_cross_win_id=""
best_cross_has_unread=0

while IFS=$'\t' read -r sess_id sess_name win_id win_index custom_unread tmux_activity bell silence seen_seq; do
  [[ -z "${sess_id:-}" ]] && continue
  [[ -z "${win_id:-}" ]] && continue
  [[ -z "${win_index:-}" ]] && continue
  session_is_excluded "${sess_name:-}" && continue

  if [[ "${custom_unread:-}" != "1" && "${tmux_activity:-}" != "1" && "${bell:-}" != "1" && "${silence:-}" != "1" ]]; then
    continue
  fi

  [[ "${win_id}" == "${current_window_id:-}" ]] && continue

  # If the only signal is tmux's activity flag, apply ignore filtering
  # (Dev Server / Codex panes should not participate in unread rotation).
  if [[ "${custom_unread:-0}" != "1" && "${tmux_activity:-0}" == "1" ]]; then
    if ~/.config/tmux/scripts/window_is_ignored.sh "${win_id}" >/dev/null 2>&1; then
      continue
    fi
  fi

  sess_idx=1000000
  if [[ "${sess_name:-}" =~ ^([0-9]+)- ]]; then
    sess_idx="${BASH_REMATCH[1]}"
  fi

  if [[ -z "${seen_seq:-}" || ! "${seen_seq}" =~ ^[0-9]+$ ]]; then
    seen_seq=0
  fi

  if [[ -z "${win_index:-}" || ! "${win_index}" =~ ^[0-9]+$ ]]; then
    continue
  fi

  if (
    ((${seen_seq} < ${best_any_seen})) ||
    ((${seen_seq} == ${best_any_seen} && ${sess_idx} < ${best_any_sess_idx})) ||
    ((${seen_seq} == ${best_any_seen} && ${sess_idx} == ${best_any_sess_idx} && ${win_index} < ${best_any_win_idx}))
  ); then
    best_any_seen="${seen_seq}"
    best_any_sess_idx="${sess_idx}"
    best_any_win_idx="${win_index}"
    best_any_sess_id="${sess_id}"
    best_any_sess_name="${sess_name}"
    best_any_win_index="${win_index}"
    best_any_win_id="${win_id}"
    best_any_has_unread=0
    [[ "${custom_unread:-}" == "1" ]] && best_any_has_unread=1
  fi

  if [[ "${sess_id}" != "${current_session_id:-}" ]]; then
    if (
      ((${seen_seq} < ${best_cross_seen})) ||
      ((${seen_seq} == ${best_cross_seen} && ${sess_idx} < ${best_cross_sess_idx})) ||
      ((${seen_seq} == ${best_cross_seen} && ${sess_idx} == ${best_cross_sess_idx} && ${win_index} < ${best_cross_win_idx}))
    ); then
      best_cross_seen="${seen_seq}"
      best_cross_sess_idx="${sess_idx}"
      best_cross_win_idx="${win_index}"
      best_cross_sess_id="${sess_id}"
      best_cross_sess_name="${sess_name}"
      best_cross_win_index="${win_index}"
      best_cross_win_id="${win_id}"
      best_cross_has_unread=0
      [[ "${custom_unread:-}" == "1" ]] && best_cross_has_unread=1
    fi
  fi
done < <(tmux list-windows -a -F $'#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{?#{==:#{@unread_activity},1},1,0}\t#{window_activity_flag}\t#{window_bell_flag}\t#{window_silence_flag}\t#{@next_unread_seen_seq}' 2>/dev/null || true)

target_id=""
target_session_name=""
target_alert=""
target_window_id=""
target_has_unread=0
if [[ "${force_cross}" == "1" && -n "${best_cross_sess_id:-}" && -n "${best_cross_win_index:-}" ]]; then
  target_id="${best_cross_sess_id}"
  target_session_name="${best_cross_sess_name}"
  target_alert="${best_cross_win_index}"
  target_window_id="${best_cross_win_id}"
  target_has_unread="${best_cross_has_unread}"
elif [[ -n "${best_any_sess_id:-}" && -n "${best_any_win_index:-}" ]]; then
  target_id="${best_any_sess_id}"
  target_session_name="${best_any_sess_name}"
  target_alert="${best_any_win_index}"
  target_window_id="${best_any_win_id}"
  target_has_unread="${best_any_has_unread}"
fi

if [[ -z "${target_id:-}" || -z "${target_alert:-}" ]]; then
  if [[ "${dry_run}" == "1" ]]; then
    debug_log "action=none_dry_run current=${current_session_name:-}(${current_session_id:-})"
    printf 'action=none current=%s(%s)\n' "$current_session_name" "$current_session_id"
    exit 0
  fi
  debug_log "action=none current=${current_session_name:-}(${current_session_id:-})"
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
  debug_log "action=global_dry_run from=${current_session_name:-}(${current_session_id:-}) to=${target_session_name:-}(${target_id:-}):${target_alert:-} window=${target_window_id:-}"
  printf 'action=global current=%s(%s) -> %s:%s window=%s\n' "$current_session_name" "$current_session_id" "$target_id" "$target_alert" "${target_window_id:-}"
  exit 0
fi

if [[ -z "${target_session_name:-}" ]]; then
  target_session_name=$(
    tmux list-sessions -F $'#{session_id}\t#{session_name}' 2>/dev/null | awk -F'\t' -v id="$target_id" '$1 == id { print $2; exit }'
  )
  [[ -z "${target_session_name:-}" ]] && target_session_name="$target_id"
fi

if [[ -n "${target_window_id:-}" ]]; then
  ~/.config/tmux/scripts/record_window_seen.sh "${target_window_id}" >/dev/null 2>&1 || true
fi

debug_log "action=global from=${current_session_name:-}(${current_session_id:-}) to=${target_session_name:-}(${target_id:-}):${target_alert:-} window=${target_window_id:-}"
tmux_switch "${target_id}:${target_alert}" || {
  debug_log "action=global_switch_failed to=${target_id:-}:${target_alert:-}"
  tmux_message "M-Tab: 切换失败（${target_session_name:-}:${target_alert:-}）"
  exit 0
}
if [[ "${target_has_unread:-0}" == "1" && -n "${target_window_id:-}" ]]; then
  unread_pane_in_target="$(first_unread_pane_in_window "${target_window_id}" "")"
  if [[ -n "${unread_pane_in_target:-}" ]]; then
    tmux_select_pane "${unread_pane_in_target}" >/dev/null 2>&1 || true
  fi
fi
if [[ -n "${current_session_name:-}" ]]; then
  if [[ "${target_id:-}" != "${current_session_id:-}" ]]; then
    ~/.config/tmux/scripts/tmux_cross_session_notify.sh "$current_session_name" "$target_session_name" "$target_alert" "${client_tty:-}" || true
  fi
fi
