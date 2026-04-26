#!/usr/bin/env bash
# desc: fzf 选择任意 session 的 window 并切换（预览 panes + 最近输出）
# usage: 无参数（在 popup 内输入关键字过滤，回车切换）
set -euo pipefail

cleanup() {
  tmux set -gu @windows_popup_open >/dev/null 2>&1 || true
  tmux set -gu @windows_popup_client >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

if ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' "fzf 未安装：请先安装 fzf（本功能依赖 fzf）。"
  pause
  exit 0
fi

windows="$(python3 "$HOME/.config/tmux/scripts/activity_rank.py" windows 2>/dev/null || true)"
if [[ -z "${windows:-}" ]]; then
  printf '%s\n' "没有可切换的 window。"
  pause
  exit 0
fi

selected="$(
  printf '%s\n' "$windows" | fzf \
    --reverse \
    --exit-0 \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --prompt='window> ' \
    --header=$'✓=待处理  ●=agent/TUI 活动  •=普通活动  ·=背景噪音  ⛶=zoom  ▶=当前 window' \
    --preview 'tmux list-panes -t {1} -F "#{pane_index}#{?pane_active,*, } #{pane_current_command}  #{pane_current_path}" 2>/dev/null; echo "----"; tmux capture-pane -p -t {1} -S -200 2>/dev/null | tail -n 200' \
    --preview-window='down,70%,wrap,follow' \
    --bind 'alt-w:abort'
)" || true

if [[ -z "${selected:-}" ]]; then
  exit 0
fi

target="${selected%%$'\t'*}"
if [[ -n "${target:-}" ]]; then
  tmux switch-client -t "$target"
fi
