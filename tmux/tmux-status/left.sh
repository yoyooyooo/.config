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

unread_counts="$(
  tmux list-windows -a -F $'#{session_id}\t#{window_id}\t#{?#{==:#{@unread_activity},1},1,0}\t#{window_activity_flag}\t#{window_bell_flag}\t#{window_silence_flag}' 2>/dev/null \
    | awk -F $'\t' '
        $3 == 1 || $4 == 1 || $5 == 1 || $6 == 1 {
          # If the only signal is tmux activity, apply ignore filtering.
          if ($3 != 1 && $4 == 1) {
            cmd = ENVIRON["HOME"] "/.config/tmux/scripts/window_is_ignored.sh " $2 " >/dev/null 2>&1"
            if (system(cmd) == 0) {
              next
            }
          }

          # Keep window tabs consistent with session counts:
          # if a window is counted due to tmux activity/bell/silence (and not ignored),
          # mirror it into @unread_activity so the window tab shows the dot too.
          if ($3 != 1 && ($4 == 1 || $5 == 1 || $6 == 1)) {
            set_cmd = "tmux set -w -t " $2 " @unread_activity 1 >/dev/null 2>&1"
            system(set_cmd)
          }

          c[$1]++
        }
        END { for (sid in c) printf "%s\t%d\n", sid, c[sid] }
      ' || true
)"

sessions=$(tmux list-sessions -F $'#{session_id}\t#{session_name}' 2>/dev/null || true)
if [[ -z "$sessions" ]]; then
  exit 0
fi

rendered=""
prev_bg=""
current_session_id_norm=$(normalize_session_id "$current_session_id")
while IFS=$'\t' read -r session_id name; do
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
  unread_count="$(awk -F $'\t' -v id="${session_id}" '$1 == id { print $2; found=1; exit } END { if (!found) print 0 }' <<<"${unread_counts}")"
  if [[ "${unread_count}" =~ ^[0-9]+$ ]] && (( unread_count > 0 )); then
    prefix_plain+="●${unread_count}"
  fi
  if [[ -n "${prefix_plain}" ]]; then
    prefix_plain+=" "
    prefix_len=${#prefix_plain}
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
