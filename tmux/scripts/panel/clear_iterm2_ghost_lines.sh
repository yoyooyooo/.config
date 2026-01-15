#!/usr/bin/env bash
# desc: 清理 iTerm2 tab 的“横线残影”（detach→reset→ClearScrollback→attach）
# usage: 在 tmux 里从 M-p 面板运行；会短暂 detach 当前 client 并自动 attach 回来
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

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

if ! require_cmd tmux; then
  die "找不到 tmux。"
fi

target_client="${ORIGIN_CLIENT:-}"
if [[ -z "${target_client:-}" || "$target_client" == *"#{"* ]]; then
  target_client="$(tmux display-message -p "#{client_name}" 2>/dev/null || true)"
fi
if [[ -z "${target_client:-}" ]]; then
  die "无法确定 target client（ORIGIN_CLIENT 缺失且无法探测）。"
fi

session_id="$(tmux display-message -p -c "$target_client" "#{session_id}" 2>/dev/null || true)"
if [[ -z "${session_id:-}" || "$session_id" == *"#{"* ]]; then
  die "无法获取当前 session_id（client=${target_client}）。"
fi

helper="$HOME/.config/tmux/scripts/iterm2_reset_and_clear_scrollback_then_attach.sh"
if [[ ! -x "$helper" ]]; then
  die "脚本不可执行：$helper（请 chmod +x）"
fi

cmd_str="$(printf '%q ' "$helper" "$session_id")"
cmd_str="${cmd_str% }"

# Replace the tmux client with a short-lived helper that resets the tab and re-attaches.
tmux detach-client -t "$target_client" -E "$cmd_str"

