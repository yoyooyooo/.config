#!/usr/bin/env bash
set -euo pipefail

# Determine theme color from tmux environments with fallback
# Prefer session env, then global env, else default.
theme_line=$(tmux show-environment TMUX_THEME_COLOR 2>/dev/null || true)
if [[ "$theme_line" == TMUX_THEME_COLOR=* ]]; then
  theme="${theme_line#TMUX_THEME_COLOR=}"
else
  theme_line=$(tmux show-environment -g TMUX_THEME_COLOR 2>/dev/null || true)
  if [[ "$theme_line" == TMUX_THEME_COLOR=* ]]; then
    theme="${theme_line#TMUX_THEME_COLOR=}"
  else
    theme="#b294bb"
  fi
fi

# Cache as a user option and apply to border style
tmux set -g @theme_color "$theme"

# Active pane border：默认使用“暖色”，可通过 `set -g @active_border_color '#RRGGBB'` 覆盖
active_border="$(tmux show -gqv @active_border_color 2>/dev/null || true)"
if [[ -z "${active_border}" ]]; then
  active_border="#ff9f43"
  tmux set -g @active_border_color "${active_border}"
fi
# 默认（尤其是单 pane window）用中性边框；多 pane 的暖色由 hooks 动态设置（update_pane_border_status.sh）
tmux set -g pane-active-border-style fg=colour244

exit 0
