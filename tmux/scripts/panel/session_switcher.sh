#!/usr/bin/env bash
# desc: fzf 选择 session 并切换（带当前 pane 预览）
# usage: 无参数（在 popup 内输入关键字过滤，回车切换）
set -euo pipefail

if ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' "fzf 未安装：请先安装 fzf（本功能依赖 fzf）。"
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
  exit 0
fi

sessions="$(python3 "$HOME/.config/tmux/scripts/activity_rank.py" sessions 2>/dev/null || true)"
if [[ -z "${sessions:-}" ]]; then
  printf '%s\n' "没有可切换的 session。"
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
  exit 0
fi

selected="$(
  printf '%s\n' "$sessions" | fzf \
    --reverse \
    --exit-0 \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --prompt='session> ' \
    --header=$'✓=待处理  ●=agent/TUI 活动  •=普通活动  ·=背景噪音' \
    --preview 'tmux capture-pane -p -t {1} -S -200 2>/dev/null | tail -n 200' \
    --preview-window='down,70%,wrap,follow'
)" || true

if [[ -n "${selected:-}" ]]; then
  target="${selected%%$'\t'*}"
  tmux switch-client -t "$target"
fi
