#!/usr/bin/env bash
# desc: fzf 选择 session，并把触发面板时的 pane 移成独立 window
# usage: 在 M-p 面板选择；回车选定目标 session
# note: 可选：--target-session <session> 用于非交互调用/测试
set -euo pipefail

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

die() {
  printf '%s\n' "$1"
  pause
  exit 0
}

tmux_has_pane() {
  local pane_id="$1"
  tmux display-message -p -t "$pane_id" '#{pane_id}' >/dev/null 2>&1
}

resolve_session_id() {
  local target="$1"
  local line session_id session_name session_label

  while IFS=$'\t' read -r session_id session_name; do
    [[ -n "${session_id:-}" && -n "${session_name:-}" ]] || continue
    session_label="$session_name"
    [[ "$session_label" =~ ^[0-9]+-(.*)$ ]] && session_label="${BASH_REMATCH[1]}"
    if [[ "$target" == "$session_id" || "$target" == "$session_name" || "$target" == "$session_label" ]]; then
      printf '%s' "$session_id"
      return 0
    fi
  done < <(tmux list-sessions -F '#{session_id}	#{session_name}' 2>/dev/null || true)

  return 1
}

last_window_id_for_session() {
  local session_id="$1"

  tmux list-windows -t "$session_id" -F '#{window_index} #{window_id}' 2>/dev/null |
    sort -n -k1,1 |
    tail -n 1 |
    cut -d ' ' -f2
}

sq() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

switch_to_pane_and_close_popup() {
  local pane_id="$1"
  local client="${ORIGIN_CLIENT:-}"
  local pane_q client_q

  pane_q="$(sq "$pane_id")"
  if [[ -n "${client:-}" && "$client" != *"#{"* ]]; then
    client_q="$(sq "$client")"
    tmux run-shell -b "tmux switch-client -c $client_q -t $pane_q >/dev/null 2>&1 || tmux switch-client -t $pane_q >/dev/null 2>&1 || true; tmux display-popup -C -c $client_q >/dev/null 2>&1 || true; sleep 0.03; tmux switch-client -c $client_q -t $pane_q >/dev/null 2>&1 || tmux switch-client -t $pane_q >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  else
    tmux run-shell -b "tmux switch-client -t $pane_q >/dev/null 2>&1 || true; tmux display-popup -C >/dev/null 2>&1 || true; sleep 0.03; tmux switch-client -t $pane_q >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
}

target_session_arg=""
while (($#)); do
  case "$1" in
    --target-session)
      target_session_arg="${2:-}"
      shift 2
      ;;
    -h|--help)
      printf '%s\n' "usage: ORIGIN_PANE_ID=%xx $0 [--target-session <session>]"
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

if ! command -v tmux >/dev/null 2>&1; then
  die "找不到 tmux。"
fi

origin_pane="${ORIGIN_PANE_ID:-}"
if [[ -z "${origin_pane:-}" || "$origin_pane" == *"#{"* ]]; then
  origin_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

if [[ -z "${origin_pane:-}" || "$origin_pane" != %* ]]; then
  die "缺少 ORIGIN_PANE_ID：请从 M-p 脚本面板启动，或手动设置 ORIGIN_PANE_ID=%xx。"
fi

if ! tmux_has_pane "$origin_pane"; then
  die "pane 不存在：${origin_pane}"
fi

origin_session_id="$(tmux display-message -p -t "$origin_pane" '#{session_id}' 2>/dev/null || true)"
origin_session_name="$(tmux display-message -p -t "$origin_pane" '#{session_name}' 2>/dev/null || true)"
origin_window_id="$(tmux display-message -p -t "$origin_pane" '#{window_id}' 2>/dev/null || true)"
origin_window_panes="$(tmux display-message -p -t "$origin_pane" '#{window_panes}' 2>/dev/null || true)"
if [[ -z "${origin_session_id:-}" || "$origin_session_id" == *"#{"* ]]; then
  die "无法解析当前 pane 所在 session（pane=${origin_pane}）。"
fi

if [[ -n "${target_session_arg:-}" ]]; then
  target_session_id="$(resolve_session_id "$target_session_arg" || true)"
  if [[ -z "${target_session_id:-}" ]]; then
    die "目标 session 不存在：${target_session_arg}"
  fi
else
  if ! command -v fzf >/dev/null 2>&1; then
    die "fzf 未安装：请先安装 fzf（本功能依赖 fzf）。"
  fi

  sessions="$(
    tmux list-sessions -F '#{session_id}	#{session_name}	#{session_windows}	#{session_attached}' 2>/dev/null |
      while IFS=$'\t' read -r session_id session_name session_windows session_attached; do
        [[ -n "${session_id:-}" && -n "${session_name:-}" ]] || continue
        mark=" "
        [[ "$session_id" == "$origin_session_id" ]] && mark="*"
        label="${mark} ${session_name}  (${session_windows} windows, attached=${session_attached})"
        printf '%s\t%s\t%s\n' "$session_id" "$session_name" "$label"
      done
  )"

  if [[ -z "${sessions:-}" ]]; then
    die "没有可用 session。"
  fi

  selected="$(
    printf '%s\n' "$sessions" | fzf \
      --reverse \
      --exit-0 \
      --delimiter=$'\t' \
      --with-nth=3 \
      --prompt='move pane to session> ' \
      --header="*=当前 session；Enter=移动 pane；Esc=取消"
  )" || true

  if [[ -z "${selected:-}" ]]; then
    exit 0
  fi

  selected_session_id="${selected%%$'\t'*}"
  target_session_id="$(resolve_session_id "$selected_session_id" || true)"
  if [[ -z "${target_session_id:-}" ]]; then
    die "目标 session 不存在：${selected_session_id}"
  fi
fi

if [[ -z "${target_session_id:-}" ]]; then
  exit 0
fi

if [[ "$target_session_id" == "$origin_session_id" && "${origin_window_panes:-1}" -le 1 ]]; then
  tmux display-message "pane ${origin_pane} 已是当前 session 的独立 window：${origin_session_name}" >/dev/null 2>&1 || true
  exit 0
fi

target_last_window_id="$(last_window_id_for_session "$target_session_id" || true)"
if [[ -z "${target_last_window_id:-}" || "$target_last_window_id" == *"#{"* || "$target_last_window_id" != @* ]]; then
  die "无法解析目标 session 的最后一个 window：${target_session_id}"
fi

break_error="$(tmux break-pane -d -a -s "$origin_pane" -t "$target_last_window_id" 2>&1 >/dev/null || true)"
new_session_id="$(tmux display-message -p -t "$origin_pane" '#{session_id}' 2>/dev/null || true)"
new_window_id="$(tmux display-message -p -t "$origin_pane" '#{window_id}' 2>/dev/null || true)"
new_window_panes="$(tmux display-message -p -t "$origin_pane" '#{window_panes}' 2>/dev/null || true)"
if [[ -z "${new_session_id:-}" || -z "${new_window_id:-}" || "$new_window_id" == *"#{"* || "$new_session_id" != "$target_session_id" || "${new_window_panes:-0}" != 1 ]]; then
  if [[ -n "${break_error:-}" ]]; then
    die "移动 pane 失败：${origin_pane} -> ${target_session_id}: ${break_error}"
  fi
  die "移动 pane 失败：${origin_pane} -> ${target_session_id}:"
fi

tmux select-layout -E -t "$origin_window_id" >/dev/null 2>&1 || true
switch_to_pane_and_close_popup "$origin_pane"
