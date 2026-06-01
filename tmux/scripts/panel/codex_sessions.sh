#!/usr/bin/env bash
# desc: Codex sessions 面板（running / unread / recent）
# usage: 在 popup 中用 fzf 选择 Codex pane，回车跳转
set -euo pipefail

client_tty="$(tmux display-message -p '#{client_tty}' 2>/dev/null || true)"
socket_path="$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)"
exec "$HOME/.config/tmux/scripts/codex_tmux_progress_panel.sh" "$client_tty" "$socket_path"
