#!/usr/bin/env bash
# desc: Codex 绑定：清空保存的 pane/session 绑定关系
# usage: 在 M-p 面板选择；将 state JSON 重置为空数组
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

state_dir="/Users/yoyo/.config/tmux/state"
state_file="$state_dir/codex-pane-bindings.json"
mkdir -p "$state_dir"

tmp_file="$state_file.tmp.$$"
printf '[]\n' > "$tmp_file"
mv "$tmp_file" "$state_file"

printf '已清空 Codex 绑定关系。\n'
printf '文件：%s\n' "$state_file"
pause
