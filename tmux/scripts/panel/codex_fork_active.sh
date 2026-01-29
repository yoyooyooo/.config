#!/usr/bin/env bash
# desc: fork 当前 pane 的 codex 会话（右侧分屏 codex fork 派生新会话）
# usage: 在 M-p 面板选择；会对触发时的 pane 执行
# note: 依赖 `~/.config/tmux/scripts/codex_session_id.py`；要求 M-p 绑定传入 ORIGIN_PANE_ID
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

target_pane="${ORIGIN_PANE_ID:-}"
if [[ -z "${target_pane:-}" ]]; then
  die "缺少 ORIGIN_PANE_ID：请在 ~/.config/tmux/tmux.conf 的 M-p 绑定里传入 ORIGIN_PANE_ID=#{pane_id}。"
fi
if [[ "$target_pane" == *"#{pane_id}"* || "$target_pane" == *"#{pane_"* || "$target_pane" == *"pane_id"* && "$target_pane" != %* ]]; then
  die "ORIGIN_PANE_ID 看起来没有被 tmux 展开成真实 pane（期望形如 %85），当前值：${target_pane}"
fi

if ! require_cmd tmux; then
  die "找不到 tmux。"
fi
if ! require_cmd python3; then
  die "找不到 python3。"
fi

session_probe="$HOME/.config/tmux/scripts/codex_session_id.py"
if [[ ! -f "$session_probe" ]]; then
  die "找不到脚本：$session_probe"
fi

session_json="$(python3 "$session_probe" --pane "$target_pane" --json 2>/dev/null || true)"
if [[ -z "${session_json:-}" ]]; then
  die "pane ${target_pane} 未检测到运行中的 codex（或无法解析会话 id）。"
fi

session_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["session_id"])' <<<"$session_json")" || die "解析 session_id 失败：${session_json}"

inner_script='codex fork '"$session_id"'; code=$?; if [[ $code -ne 0 ]]; then echo; echo "codex fork 失败 (exit $code)"; read -r -n 1 -s -p "按任意键关闭..." || true; echo; fi'
resume_cmd="bash -lc '$inner_script'"

smart_split="$HOME/.config/tmux/scripts/smart_split_133.sh"
if [[ ! -x "$smart_split" ]]; then
  die "找不到脚本：$smart_split"
fi

if ! split_json="$(TMUX_SMART_SPLIT_JSON=1 TMUX_SMART_SPLIT_CMD="$resume_cmd" "$smart_split" "$target_pane" 2>&1)"; then
  die "智能分屏失败：${split_json}"
fi

new_pane="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("pane_id",""))' <<<"$split_json" 2>/dev/null || true)"
if [[ -z "${new_pane:-}" || "$new_pane" != %* ]]; then
  die "解析新 pane_id 失败：${split_json}"
fi

tmux send-keys -t "$new_pane" -X cancel >/dev/null 2>&1 || true
