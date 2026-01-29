#!/usr/bin/env bash
# desc: 兼容旧脚本入口：按 1+2+2 → 1+3+3 规则新增后台 pane（最多 7 panes）
# usage:
#   CODEX_PANE_ID=%85 bash ~/.config/tmux/scripts/codex_spawn_background_pane.sh
set -euo pipefail

export TMUX_SMART_SPLIT_DETACH=1
export TMUX_SMART_SPLIT_JSON=1

exec "$HOME/.config/tmux/scripts/smart_split_133.sh" "${1:-}"

