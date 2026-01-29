#!/usr/bin/env bash
# desc: Spec 预览（选择 specs/<NNN-*> 并用 fzf + bat 浏览文件）
# usage: 进入后可直接搜索 spec 目录；再选文件预览/编辑
set -euo pipefail

core="$HOME/.config/tmux/scripts/spec_preview.sh"

pause() {
  local prompt="${1:-按任意键关闭...}"
  if [[ -t 1 ]]; then
    if [[ -r /dev/tty ]]; then
      read -r -n 1 -s -p "$prompt" < /dev/tty || true
    else
      read -r -n 1 -s -p "$prompt" || true
    fi
    printf '\n'
  fi
}

if [[ ! -x "$core" ]]; then
  printf '%s\n' "找不到或不可执行：$core"
  pause
  exit 0
fi

# 目标行为：选中后关闭 panel popup，然后再打开 spec popup。
# 由于当前脚本是在 panel popup 内执行，直接 display-popup 可能被拒绝/产生竞态；
# 这里用 run-shell -b：先关闭 panel popup，再打开 spec popup（不依赖 sleep）。
sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

if command -v tmux >/dev/null 2>&1; then
  client="$(tmux display-message -p '#{client_name}' 2>/dev/null || true)"
  start_dir="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)"
  if [[ -n "${client:-}" ]]; then
    cmd="tmux display-popup -E -w 95% -h 90% -T spec"
    cmd+=" -e $(sq "SPEC_PREVIEW_CLIENT=$client")"
    cmd+=" -e $(sq "SPEC_PREVIEW_IN_POPUP=1")"
    cmd+=" -c $(sq "$client")"
    if [[ -n "${start_dir:-}" ]]; then
      cmd+=" -e $(sq "SPEC_PREVIEW_START_DIR=$start_dir")"
      cmd+=" -d $(sq "$start_dir")"
    fi
    cmd+=" $(sq "$core")"

    # 注意：tmux run-shell（未加 -C）会在命令结束后把 stdout/失败状态展示到 view mode；
    # 而 `tmux display-popup` 会等待 popup 里的命令退出，并把其退出码作为自己的退出码（例如 fzf ESC=130）。
    # 所以这里强制吞掉输出并把退出码归零，避免回到 pane 时“进入 copy/view mode 且置顶一条 tmux 命令”。
    tmux run-shell -b "tmux display-popup -C -c $(sq "$client") >/dev/null 2>&1 || true; $cmd >/dev/null 2>&1 || true; true"
    exit 0
  fi
fi

exec "$core"
