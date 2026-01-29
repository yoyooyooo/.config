#!/usr/bin/env bash
# desc: 在当前 window 按“就近分屏”规则新增一个 pane（最多 7 panes）
# - <3 列：对 origin pane 向右加列（可插入到中间）
# - 3 列：优先对 origin 所在列向下加行（可在列中间插入）
# usage:
#   bash ~/.config/tmux/scripts/smart_split_133.sh [<origin_pane_id>]
#
# env:
#   ORIGIN_PANE_ID / CODEX_PANE_ID: 指定 origin pane（优先于参数）
#   CODEX_WINDOW_ID: 指定目标 window_id（可选）
#   TMUX_SMART_SPLIT_DETACH=1: 新 pane 不抢焦点（默认抢焦点）
#   TMUX_SMART_SPLIT_JSON=1: 输出 JSON（默认无输出）
#   TMUX_SMART_SPLIT_CMD: 以该命令启动新 pane（可选；不指定则启动默认 shell）
set -euo pipefail

# shellcheck disable=SC1090
if [[ -f "$HOME/.config/tmux/scripts/lib/tmux_kit_proxy.sh" ]]; then
  source "$HOME/.config/tmux/scripts/lib/tmux_kit_proxy.sh"
fi

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

die() {
  local msg="$1"
  if require_cmd tmux; then
    tmux display-message "smart-split: ${msg}" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "smart-split: ${msg}" >&2
  exit 1
}

resolve_origin_pane() {
  local pane="${ORIGIN_PANE_ID:-${CODEX_PANE_ID:-}}"
  if [[ -z "${pane:-}" ]]; then
    pane="${1:-}"
  fi
  if [[ -z "${pane:-}" ]]; then
    pane="${TMUX_PANE:-}"
  fi
  if [[ -z "${pane:-}" || "$pane" == *"#{"* || "$pane" != %* ]]; then
    die "未能确定目标 pane（期望形如 %<number>）。"
  fi
  printf '%s' "$pane"
}

resolve_window_id() {
  local pane="$1"
  local window="${CODEX_WINDOW_ID:-}"
  if [[ -n "${window:-}" ]]; then
    printf '%s' "$window"
    return 0
  fi
  window="$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null || true)"
  if [[ -z "${window:-}" || "$window" == *"#{"* ]]; then
    die "无法从 pane ${pane} 解析 window_id。"
  fi
  printf '%s' "$window"
}

find_col_index() {
  local left="$1"
  local idx=0
  for existing in "${col_lefts[@]:-}"; do
    if [[ "$existing" == "$left" ]]; then
      printf '%s' "$idx"
      return 0
    fi
    idx=$((idx + 1))
  done
  printf '%s' "-1"
}

if ! require_cmd tmux; then
  die "找不到 tmux。"
fi

origin_pane="$(resolve_origin_pane "${1:-}")"
pane_ok="$(tmux display-message -p -t "$origin_pane" '#{pane_id}' 2>/dev/null || true)"
if [[ "${pane_ok:-}" != "$origin_pane" ]]; then
  die "找不到 tmux pane：${origin_pane}"
fi

window_id="$(resolve_window_id "$origin_pane")"
origin_path="$(tmux display-message -p -t "$origin_pane" '#{pane_current_path}' 2>/dev/null || true)"
if [[ -z "${origin_path:-}" || "$origin_path" == *"#{"* ]]; then
  origin_path="$HOME"
fi

pane_rows="$(tmux list-panes -t "$window_id" -F '#{pane_id}|#{pane_left}|#{pane_top}' 2>/dev/null || true)"
if [[ -z "${pane_rows:-}" ]]; then
  die "无法列出 window ${window_id} 的 panes。"
fi

col_lefts=()
col_counts=()
col_bottom_pane=()
col_bottom_top=()

total_panes=0
sorted_rows="$(printf '%s\n' "$pane_rows" | sort -t '|' -n -k2,2 -k3,3)"
while IFS='|' read -r pane_id pane_left pane_top; do
  [[ -n "${pane_id:-}" ]] || continue
  total_panes=$((total_panes + 1))
  col_idx="$(find_col_index "$pane_left")"
  if [[ "$col_idx" -lt 0 ]]; then
    col_idx="${#col_lefts[@]}"
    col_lefts+=("$pane_left")
    col_counts+=("0")
    col_bottom_pane+=("")
    col_bottom_top+=("-1")
  fi

  col_counts[$col_idx]=$((col_counts[$col_idx] + 1))
  if [[ -z "${col_bottom_pane[$col_idx]:-}" || "$pane_top" -gt "${col_bottom_top[$col_idx]}" ]]; then
    col_bottom_pane[$col_idx]="$pane_id"
    col_bottom_top[$col_idx]="$pane_top"
  fi
done <<<"$sorted_rows"

col_count="${#col_lefts[@]}"
if [[ "$col_count" -eq 0 ]]; then
  die "window ${window_id} 内未检测到 panes。"
fi

if (( total_panes >= 7 )); then
  die "已达到最大分屏数（1+3+3，共 7 panes），不再新增。"
fi

detach="${TMUX_SMART_SPLIT_DETACH:-0}"
json="${TMUX_SMART_SPLIT_JSON:-0}"
cmd="${TMUX_SMART_SPLIT_CMD:-}"

fallback_split_right() {
  local new_pane
  split_args=(split-window -h -P -F '#{pane_id}' -t "$origin_pane")
  if [[ "$detach" == "1" ]]; then
    split_args+=(-d)
  fi
  if [[ -n "${origin_path:-}" ]]; then
    split_args+=(-c "$origin_path")
  fi
  if [[ -n "${cmd:-}" ]]; then
    split_args+=("$cmd")
  fi
  new_pane="$(tmux "${split_args[@]}" 2>/dev/null || true)"
  [[ -n "${new_pane:-}" ]] || die "新增 pane 失败。"
  if [[ "$detach" != "1" ]]; then
    tmux select-pane -t "$new_pane" >/dev/null 2>&1 || true
  fi
  if [[ "$json" == "1" ]]; then
    printf '{"status":"ok","pane_id":"%s","window_id":"%s","action":"%s","total_panes":%d}\n' \
      "$new_pane" "$window_id" "fallback_split_right" "$((total_panes + 1))"
  fi
  exit 0
}

# ---- 智能布局约束（不满足则回退为普通 split-right） ----

if (( col_count > 3 )); then
  fallback_split_right
fi

if (( col_counts[0] != 1 )); then
  fallback_split_right
fi

if (( col_count == 2 )) && (( col_counts[1] != 1 )); then
  fallback_split_right
fi

if (( col_count >= 2 )) && (( col_counts[1] > 3 )); then
  fallback_split_right
fi
if (( col_count >= 3 )) && (( col_counts[2] > 3 )); then
  fallback_split_right
fi

action=""
target_pane=""
target_column=0

origin_left="$(tmux display-message -p -t "$origin_pane" '#{pane_left}' 2>/dev/null || true)"
if [[ -z "${origin_left:-}" || "$origin_left" == *"#{"* ]]; then
  fallback_split_right
fi
origin_col_idx="$(find_col_index "$origin_left")"
if [[ "${origin_col_idx:-}" -lt 0 ]]; then
  fallback_split_right
fi

if (( col_count < 3 )); then
  action="add_column"
  target_pane="$origin_pane"
  target_column=$((origin_col_idx + 2))
  split_args=(split-window -h -P -F '#{pane_id}' -t "$target_pane")
else
  action="add_row"

  if (( origin_col_idx == 0 )); then
    if (( col_counts[1] < 2 )); then
      target_column=2
      target_pane="${col_bottom_pane[1]}"
    elif (( col_counts[2] < 2 )); then
      target_column=3
      target_pane="${col_bottom_pane[2]}"
    elif (( col_counts[1] < 3 )); then
      target_column=2
      target_pane="${col_bottom_pane[1]}"
    elif (( col_counts[2] < 3 )); then
      target_column=3
      target_pane="${col_bottom_pane[2]}"
    else
      die "columns 2/3 已满（1+3+3），不再新增。"
    fi
  else
    target_column=$((origin_col_idx + 1))
    target_pane="$origin_pane"

    if (( col_counts[origin_col_idx] >= 3 )); then
      other_col_idx=1
      if (( origin_col_idx == 1 )); then
        other_col_idx=2
      fi

      if (( col_counts[other_col_idx] >= 3 )); then
        die "columns 2/3 已满（1+3+3），不再新增。"
      fi

      target_column=$((other_col_idx + 1))
      target_pane="${col_bottom_pane[$other_col_idx]}"
    fi
  fi

  split_args=(split-window -v -P -F '#{pane_id}' -t "$target_pane")
fi

if [[ "$detach" == "1" ]]; then
  split_args+=(-d)
fi
if [[ -n "${origin_path:-}" ]]; then
  split_args+=(-c "$origin_path")
fi
if [[ -n "${cmd:-}" ]]; then
  split_args+=("$cmd")
fi
new_pane="$(tmux "${split_args[@]}" 2>/dev/null || true)"

[[ -n "${new_pane:-}" ]] || die "新增 pane 失败。"
if [[ "$detach" != "1" ]]; then
  tmux select-pane -t "$new_pane" >/dev/null 2>&1 || true
fi

if [[ "$json" == "1" ]]; then
  printf '{"status":"ok","pane_id":"%s","window_id":"%s","action":"%s","column":%d,"total_panes":%d}\n' \
    "$new_pane" "$window_id" "$action" "$target_column" "$((total_panes + 1))"
fi
