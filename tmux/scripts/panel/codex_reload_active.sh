#!/usr/bin/env bash
# desc: reload active codex（中断运行中的 codex 并 cx resume 会话）
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

session_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["session_id"])' <<<"$session_json")"

matched_pids="$(python3 -c 'import json,sys; print(" ".join(str(p) for p in json.load(sys.stdin).get("matched_pids", [])))' <<<"$session_json")"

pid_alive() {
  local pid="$1"
  kill -0 "$pid" >/dev/null 2>&1
}

any_pid_alive() {
  local pid
  for pid in ${matched_pids:-}; do
    if pid_alive "$pid"; then
      return 0
    fi
  done
  return 1
}

tmux send-keys -t "$target_pane" -X cancel >/dev/null 2>&1 || true

# 先尝试“像人一样”发两次 C-c
tmux send-keys -t "$target_pane" C-c >/dev/null 2>&1 || true
sleep 0.05
tmux send-keys -t "$target_pane" C-c >/dev/null 2>&1 || true

# 有界等待：若仍在跑，再补一轮 SIGINT → SIGTERM
if any_pid_alive && [[ -n "${matched_pids:-}" ]]; then
  for pid in $matched_pids; do
    kill -INT "$pid" >/dev/null 2>&1 || true
  done
fi

for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ! any_pid_alive; then
    break
  fi
  sleep 0.12
done

if any_pid_alive && [[ -n "${matched_pids:-}" ]]; then
  for pid in $matched_pids; do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  for _ in 1 2 3 4 5 6 7 8; do
    if ! any_pid_alive; then
      break
    fi
    sleep 0.12
  done
fi

if any_pid_alive; then
  die "无法在限定时间内退出 codex（pane ${target_pane}）。可手动退出后再执行：cx resume ${session_id}"
fi

tmux send-keys -t "$target_pane" -X cancel >/dev/null 2>&1 || true
tmux send-keys -t "$target_pane" -l "cx resume $session_id" >/dev/null 2>&1 || true
tmux send-keys -t "$target_pane" Enter >/dev/null 2>&1 || true
