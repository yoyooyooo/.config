#!/usr/bin/env bash
set -euo pipefail

current_session_id="${1:-}"
current_session_name="${2:-}"

# Single tmux call to get all needed info
IFS=$'\t' read -r detect_session_id detect_session_name term_width status_bg < <(
  tmux display-message -p '#{session_id}	#{session_name}	#{client_width}	#{status-bg}' 2>/dev/null || echo ""
)

[[ -z "$current_session_id" ]] && current_session_id="$detect_session_id"
[[ -z "$current_session_name" ]] && current_session_name="$detect_session_name"
[[ -z "$status_bg" || "$status_bg" == "default" ]] && status_bg=black
term_width="${term_width:-100}"

inactive_bg="#373b41"
inactive_fg="#c5c8c6"
active_bg="${TMUX_THEME_COLOR:-#b294bb}"
active_fg="#1d1f21"
separator=""
left_cap=""
max_width=18

left_narrow_width=${TMUX_LEFT_NARROW_WIDTH:-80}
is_narrow=0
[[ "$term_width" =~ ^[0-9]+$ ]] && (( term_width < left_narrow_width )) && is_narrow=1

normalize_session_id() {
  local value="$1"
  value="${value#\$}"
  printf '%s' "$value"
}

trim_label() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+-(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$value"
  fi
}

extract_index() {
  local value="$1"
  if [[ "$value" =~ ^([0-9]+)-.*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf ''
  fi
}

count_session_alerts() {
  local alerts="${1:-}"
  [[ -z "${alerts}" ]] && printf '0' && return 0

  local -a parts
  declare -A seen=()
  local part idx count
  count=0

  IFS=',' read -r -a parts <<<"${alerts}"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    idx="${part%%[^0-9]*}"
    [[ -z "${idx}" ]] && continue
    if [[ -z "${seen[$idx]+x}" ]]; then
      seen[$idx]=1
      count=$((count + 1))
    fi
  done

  printf '%s' "${count}"
}



sessions=$(tmux list-sessions -F $'#{session_id}\t#{session_name}\t#{session_alerts}' 2>/dev/null || true)
if [[ -z "$sessions" ]]; then
  exit 0
fi

declare -A session_codex_done_counts=()
windows=$(tmux list-windows -a -F $'#{session_id}\t#{@codex_done}' 2>/dev/null || true)
if [[ -n "${windows}" ]]; then
  while IFS=$'\t' read -r win_session_id win_codex_done; do
    [[ -n "${win_session_id:-}" ]] || continue
    [[ "${win_codex_done:-}" == "1" ]] || continue
    win_session_id_norm=$(normalize_session_id "${win_session_id}")
    current_count="${session_codex_done_counts[${win_session_id_norm}]:-0}"
    if [[ "${current_count}" =~ ^[0-9]+$ ]]; then
      session_codex_done_counts[${win_session_id_norm}]=$((current_count + 1))
    else
      session_codex_done_counts[${win_session_id_norm}]=1
    fi
  done <<<"${windows}"
fi

rendered=""
prev_bg=""
current_session_id_norm=$(normalize_session_id "$current_session_id")
while IFS=$'\t' read -r session_id name session_alerts; do
  [[ -z "${session_id:-}" ]] && continue
  [[ -z "${name:-}" ]] && continue

  session_id_norm=$(normalize_session_id "$session_id")
  segment_bg="$inactive_bg"
  segment_fg="$inactive_fg"
  trimmed_name=$(trim_label "$name")
  is_current=0
  if [[ "$session_id" == "$current_session_id" || "$session_id_norm" == "$current_session_id_norm" ]]; then
    is_current=1
    segment_bg="$active_bg"
    segment_fg="$active_fg"
  fi

  if (( is_narrow == 1 )); then
    if (( is_current == 1 )); then
      label="$trimmed_name"  # active: show TITLE (trim N-)
    else
      idx=$(extract_index "$name")
      if [[ -n "$idx" ]]; then
        label="$idx"
      else
        label="$trimmed_name"
      fi
    fi
  else
    label="$trimmed_name"      # wide: current behavior (TITLE everywhere)
  fi

  prefix_render=""
  prefix_plain=""
  prefix_len=0
  done_count="${session_codex_done_counts[${session_id_norm}]:-0}"
  unread_count=$(count_session_alerts "${session_alerts:-}")
  if [[ "${done_count}" =~ ^[0-9]+$ ]] && (( done_count > 0 )); then
    prefix_plain+="●${done_count}"
  fi
  if [[ "${unread_count}" =~ ^[0-9]+$ ]] && (( unread_count > 0 )); then
    prefix_plain+="●${unread_count}"
  fi
  if [[ -n "${prefix_plain}" ]]; then
    prefix_plain+=" "
    prefix_len=${#prefix_plain}
    if [[ "${done_count}" =~ ^[0-9]+$ ]] && (( done_count > 0 )); then
      prefix_render+="#[fg=#3fb950,bold]●${done_count}"
    fi
    if [[ "${unread_count}" =~ ^[0-9]+$ ]] && (( unread_count > 0 )); then
      prefix_render+="#[fg=colour208,bold]●${unread_count}"
    fi
    prefix_render+="#[fg=${segment_fg},nobold] "
  fi

  label_max_width=$max_width
  if (( prefix_len > 0 )); then
    label_max_width=$(( max_width - prefix_len ))
    (( label_max_width < 1 )) && label_max_width=1
  fi
  if (( ${#label} > label_max_width )); then
    label="${label:0:label_max_width-1}…"
  fi

  if [[ -z "$prev_bg" ]]; then
    rendered+="#[fg=${segment_bg},bg=${status_bg}]${left_cap}"
  else
    rendered+="#[fg=${prev_bg},bg=${segment_bg}]${separator}"
  fi
  rendered+="#[fg=${segment_fg},bg=${segment_bg},range=session|${session_id}] ${prefix_render}${label} #[fg=${segment_fg},bg=${segment_bg},norange]"
  prev_bg="$segment_bg"
done <<< "$sessions"

if [[ -n "$prev_bg" ]]; then
  rendered+="#[fg=${prev_bg},bg=${status_bg}]${separator}"
fi

printf '%s' "$rendered"
