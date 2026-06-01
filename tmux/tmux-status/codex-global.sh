#!/usr/bin/env bash
set -euo pipefail

status_bg=$(tmux show -gqv status-bg)
if [[ -z "$status_bg" ]]; then
  status_bg=default
fi

segment_bg="${TMUX_STATUS_RIGHT_BG:-${TMUX_SESSION_INACTIVE_BG:-#3d434a}}"
segment_fg="#eceff4"
separator=""
right_cap=""
yellow="#EAB308"
green="#3fb950"

field_sep='|'
IFS="$field_sep" read -r in_progress unread < <(
  tmux display-message -p "#{@codex_total_in_progress_count}${field_sep}#{@codex_total_unread_count}" 2>/dev/null || printf '%s' "$field_sep"
)

[[ "${in_progress:-}" =~ ^[0-9]+$ ]] || in_progress=0
[[ "${unread:-}" =~ ^[0-9]+$ ]] || unread=0

if (( in_progress == 0 && unread == 0 )); then
  exit 0
fi

parts=()
if (( in_progress > 0 )); then
  parts+=("#[fg=${yellow},bg=${segment_bg},range=user|cxrun]●${in_progress}#[fg=${segment_fg},bg=${segment_bg},range=user|cxrun] running#[norange]")
fi
if (( unread > 0 )); then
  parts+=("#[fg=${green},bg=${segment_bg},range=user|cxunread]●${unread}#[fg=${segment_fg},bg=${segment_bg},range=user|cxunread] unread#[norange]")
fi

joined="${parts[0]}"
if (( ${#parts[@]} > 1 )); then
  joined+=" #[fg=colour244,bg=${segment_bg}]│ ${parts[1]}"
fi

printf '#[fg=%s,bg=%s]%s#[fg=%s,bg=%s] %s#[fg=%s,bg=%s]%s' \
  "$segment_bg" "$status_bg" "$separator" \
  "$segment_fg" "$segment_bg" "$joined" \
  "$segment_bg" "$status_bg" "$right_cap"
