#!/usr/bin/env bash
# desc: right.codes 当日余额（remaining + USD）
# usage: 选择后弹出 popup，展示 remaining + unit
set -euo pipefail

core="$HOME/.config/tmux/scripts/ccswitch_right_codes_balance.sh"

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

if [[ ! -x "$core" ]]; then
  printf '%s\n' "找不到或不可执行：$core"
  pause
  exit 0
fi

exec "$core"
