#!/usr/bin/env bash
# desc: reload active codex（中断运行中的 codex 并恢复会话；默认用 codex，可用 cx/自定义）
# usage: 在 M-p 面板选择；会对触发时的 pane 执行
# note: 依赖 `~/.config/tmux/extensions/codex/scripts/tmux_codex_session_id.py`；要求 M-p 绑定传入 ORIGIN_PANE_ID
set -euo pipefail

noninteractive() {
  [[ "${CODEX_RELOAD_NONINTERACTIVE:-}" == "1" ]]
}

pause() {
  if noninteractive; then
    return 0
  fi
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

die() {
  printf '%s\n' "$1"
  pause
  if noninteractive; then
    exit 1
  fi
  exit 0
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

resolve_codex_cli() {
  local bin="${CODEX_CLI_BIN:-}"
  if [[ -z "${bin:-}" ]]; then
    if command -v codex >/dev/null 2>&1; then
      bin="codex"
    elif command -v cx >/dev/null 2>&1; then
      bin="cx"
    fi
  fi

  if [[ -z "${bin:-}" ]]; then
    return 1
  fi

  if [[ "${bin}" == */* ]]; then
    [[ -x "${bin}" ]] || return 1
    printf '%s' "${bin}"
    return 0
  fi

  command -v "${bin}" >/dev/null 2>&1 || return 1
  printf '%s' "${bin}"
  return 0
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

codex_cli="$(resolve_codex_cli || true)"
if [[ -z "${codex_cli:-}" ]]; then
  die "找不到 Codex CLI（需要 `codex`；或设置 CODEX_CLI_BIN；或自行提供别名 `cx`）。"
fi

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session_probe="${CODEX_CODEX_SESSION_PROBE:-${CODEX_SESSION_PROBE:-}}"
if [[ -z "${session_probe:-}" ]]; then
  session_probe="$script_dir/../tmux_codex_session_id.py"
  if [[ ! -f "$session_probe" ]]; then
    session_probe="$HOME/.config/tmux/extensions/codex/scripts/tmux_codex_session_id.py"
  fi
fi
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
  die "无法在限定时间内退出 codex（pane ${target_pane}）。可手动退出后再执行：${codex_cli} resume ${session_id}"
fi

target_cwd="${TARGET_CWD:-${CODEX_TARGET_CWD:-}}"
resume_line="${codex_cli} resume $session_id"
if [[ -n "${target_cwd:-}" ]]; then
  if [[ ! -d "${target_cwd:-}" ]]; then
    die "目录不存在：${target_cwd}"
  fi
  resume_line="cd -- $(shell_quote "$target_cwd") && ${codex_cli} resume $session_id"
fi

tmux send-keys -t "$target_pane" -l "$resume_line" >/dev/null 2>&1 || true
tmux send-keys -t "$target_pane" Enter >/dev/null 2>&1 || true
