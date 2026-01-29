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

# popup UI 检测依赖 TMUX + TMUX_PANE（agent-tmux 内部会校验）。
tmux_env="${TMUX:-}"
if [[ -z "${tmux_env:-}" ]]; then
  die "缺少 TMUX 环境变量（需要在 tmux 内运行）。"
fi

# 确保 tmux server 侧也能找到 gum（以及其它 Homebrew 工具）。
path_env="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
case ":$path_env:" in
  *":/opt/homebrew/bin:"*) ;;
  *) path_env="/opt/homebrew/bin:$path_env" ;;
esac
case ":$path_env:" in
  *":/usr/local/bin:"*) ;;
  *) path_env="/usr/local/bin:$path_env" ;;
esac

# 关键：避免在 panel popup 里“套娃 popup”导致 tmux 拒绝打开。
# 在 tmux server 后台启动真正的 popup 命令；当前脚本直接退出以关闭 panel。
log_dir="$HOME/.config/tmux/run"
mkdir -p "$log_dir" >/dev/null 2>&1 || true
log_file="$log_dir/codex_user_nodes.last.log"
origin_client="${ORIGIN_CLIENT:-}"
{
  printf 'ts=%s\n' "$(date -Is 2>/dev/null || date)"
  printf 'origin_pane=%s\n' "$target_pane"
  printf 'origin_client=%s\n' "${origin_client:-}"
} >"$log_file" 2>/dev/null || true

inner="$(
  cat <<'BASH'
agent_tmux=__AGENT_TMUX__
target_pane=__TARGET_PANE__
origin_client=__ORIGIN_CLIENT__
tmux_env=__TMUX_ENV__
path_env=__PATH_ENV__
log_file="$HOME/.config/tmux/run/codex_user_nodes.last.log"

mkdir -p "$(dirname "$log_file")" >/dev/null 2>&1 || true
{
  printf 'ts=%s\n' "$(date -Is 2>/dev/null || date)"
  printf 'origin_pane=%s\n' "$target_pane"
  printf 'origin_client=%s\n' "$origin_client"
} >"$log_file" 2>/dev/null || true

tmux display-message -d 4000 ${origin_client:+-c "$origin_client"} "codex user-nodes: pick & scroll..."
sleep 0.2

set +e
out="$(PATH="$path_env" TMUX="$tmux_env" TMUX_PANE="$target_pane" "$agent_tmux" codex user-nodes --popup --open scroll --scroll-padding 2 "$target_pane" 2>>"$log_file")"
ec=$?
set -e

printf 'exit_code=%s\n' "$ec" >>"$log_file" 2>/dev/null || true
out="$(printf '%s' "$out" | tr -d '\r' | tail -n 1)"

if [[ "$ec" -ne 0 ]]; then
  tmux display-message -d 5000 ${origin_client:+-c "$origin_client"} "codex user-nodes failed ($ec). see: $log_file"
  exit 0
fi

if [[ -n "$out" ]]; then
  printf 'selected_line=%s\n' "$out" >>"$log_file" 2>/dev/null || true
  tmux set -g @codex_user_nodes_last_line "$out" >/dev/null 2>&1 || true
  tmux display-message -d 4000 ${origin_client:+-c "$origin_client"} "codex user-nodes: scrolled (line $out)"
else
  tmux display-message -d 4000 ${origin_client:+-c "$origin_client"} "codex user-nodes: cancelled"
fi
exit 0
BASH
)"
inner="${inner/__AGENT_TMUX__/$(sq "$agent_tmux")}"
inner="${inner/__TARGET_PANE__/$(sq "$target_pane")}"
inner="${inner/__ORIGIN_CLIENT__/$(sq "$origin_client")}"
inner="${inner/__TMUX_ENV__/$(sq "$tmux_env")}"
inner="${inner/__PATH_ENV__/$(sq "$path_env")}"
cmd="bash -lc $(sq "$inner")"
tmux run-shell -b "$cmd" >/dev/null 2>&1 || true
