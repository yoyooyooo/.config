#!/usr/bin/env bash
# desc: Codex：选用户节点后在当前 pane 滚动定位（copy-mode search）
# usage: 在 M-p 面板选择；要求 M-p 绑定已设置 @panel_origin_pane_id
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

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

target_pane="${ORIGIN_PANE_ID:-}"
if [[ -z "${target_pane:-}" ]]; then
  die "缺少 ORIGIN_PANE_ID：请使用 M-p 打开 panel（它会设置 @panel_origin_pane_id）。"
fi
if [[ "$target_pane" != %* || "$target_pane" == *"#{"* ]]; then
  die "ORIGIN_PANE_ID 看起来未被展开为真实 pane（期望形如 %85），当前值：${target_pane}"
fi

agent_tmux="$(command -v agent-tmux 2>/dev/null || true)"
if [[ -z "${agent_tmux:-}" ]]; then
  die "找不到 agent-tmux（请确认已安装/在 PATH 中）。"
fi

tmux_env="${TMUX:-}"
if [[ -z "${tmux_env:-}" ]]; then
  die "缺少 TMUX 环境变量（需要在 tmux 内运行）。"
fi

path_env="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
case ":$path_env:" in
  *":/opt/homebrew/bin:"*) ;;
  *) path_env="/opt/homebrew/bin:$path_env" ;;
esac
case ":$path_env:" in
  *":/usr/local/bin:"*) ;;
  *) path_env="/usr/local/bin:$path_env" ;;
esac

log_dir="$HOME/.config/tmux/run"
mkdir -p "$log_dir" >/dev/null 2>&1 || true
log_file="$log_dir/codex_user_nodes_scroll.last.log"
origin_client="${ORIGIN_CLIENT:-}"
{
  printf 'ts=%s\n' "$(date -Is 2>/dev/null || date)"
  printf 'origin_pane=%s\n' "$target_pane"
  printf 'origin_client=%s\n' "${origin_client:-}"
} >"$log_file" 2>/dev/null || true

inner="tmux display-message -d 1200 ${origin_client:+-c $(sq "$origin_client")} \"codex user-nodes: pick & scroll...\"; sleep 0.2; PATH=$(sq "$path_env") TMUX=$(sq "$tmux_env") TMUX_PANE=$(sq "$target_pane") $(sq "$agent_tmux") codex user-nodes --popup --open scroll $(sq "$target_pane") >>$(sq "$log_file") 2>&1; ec=\$?; if [ \$ec -ne 0 ]; then tmux display-message -d 5000 ${origin_client:+-c $(sq "$origin_client")} \"codex user-nodes scroll failed (\$ec). see: $log_file\"; fi; exit 0"
cmd="bash -lc $(sq "$inner")"
tmux run-shell -b "$cmd" >/dev/null 2>&1 || true

