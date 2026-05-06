#!/usr/bin/env bash
# desc: 导出当前 Codex 最后一条回复到 Obsidian 临时预览 tab
# usage: 在 M-p 面板选择；写入 CODEX_OBSIDIAN_PREVIEW_DIR/Codex Last Message.md，并在 Obsidian 新 tab 打开
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

resolve_obsidian_bin() {
  local configured="${CODEX_OBSIDIAN_CLI_BIN:-}"
  if [[ -n "${configured:-}" ]]; then
    if [[ -x "$configured" ]]; then
      printf '%s\n' "$configured"
      return 0
    fi
    return 1
  fi

  if command -v obsidian >/dev/null 2>&1; then
    command -v obsidian
    return 0
  fi

  local macos_app_bin="/Applications/Obsidian.app/Contents/MacOS/obsidian"
  if [[ -x "$macos_app_bin" ]]; then
    printf '%s\n' "$macos_app_bin"
    return 0
  fi

  return 1
}

target_pane="${ORIGIN_PANE_ID:-}"
if [[ -z "${target_pane:-}" ]]; then
  die "缺少 ORIGIN_PANE_ID：请使用 M-p 打开 panel（它会设置 @panel_origin_pane_id）。"
fi
if [[ "$target_pane" == *"#{pane_id}"* || "$target_pane" == *"#{pane_"* || "$target_pane" == *"pane_id"* && "$target_pane" != %* ]]; then
  die "ORIGIN_PANE_ID 看起来没有被 tmux 展开成真实 pane（期望形如 %85），当前值：${target_pane}"
fi

if ! require_cmd python3; then
  die "找不到 python3。"
fi
if ! require_cmd osascript; then
  die "找不到 osascript，无法把 Obsidian 窗口置于前台。"
fi
obsidian_bin="$(resolve_obsidian_bin || true)"
if [[ -z "${obsidian_bin:-}" ]]; then
  die "找不到 obsidian CLI。可设置 CODEX_OBSIDIAN_CLI_BIN=/Applications/Obsidian.app/Contents/MacOS/obsidian"
fi

session_probe="$HOME/.config/tmux/scripts/codex_session_id.py"
if [[ ! -f "$session_probe" ]]; then
  die "找不到脚本：$session_probe"
fi

session_json="$(python3 "$session_probe" --pane "$target_pane" --json 2>/dev/null || true)"
if [[ -z "${session_json:-}" ]]; then
  die "pane ${target_pane} 未检测到运行中的 codex（或无法解析会话 id）。"
fi

vault_name="${CODEX_OBSIDIAN_VAULT_NAME:-personal}"
vault_dir="${CODEX_OBSIDIAN_VAULT_DIR:-/Users/yoyo/Documents/note/obsidian/personal}"
preview_dir="${CODEX_OBSIDIAN_PREVIEW_DIR:-$vault_dir/inbox/codex-preview}"
preview_file_name="${CODEX_OBSIDIAN_PREVIEW_FILE:-Codex Last Message.md}"

export SESSION_JSON="$session_json"
export CODEX_OBSIDIAN_VAULT_DIR="$vault_dir"
export CODEX_OBSIDIAN_PREVIEW_DIR="$preview_dir"
export CODEX_OBSIDIAN_PREVIEW_FILE="$preview_file_name"

write_json="$(
  python3 <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def extract_text(rollout_path: Path) -> str:
    last_text: str | None = None
    try:
        lines = rollout_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        fail(f"找不到 rollout 文件：{rollout_path}")

    for line in lines:
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = event.get("payload")
        if not isinstance(payload, dict):
            continue
        if payload.get("role") != "assistant":
            continue
        content = payload.get("content")
        if not isinstance(content, list):
            continue
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") != "output_text":
                continue
            text = item.get("text")
            if isinstance(text, str):
                parts.append(text)
        if parts:
            last_text = "\n".join(parts)

    if last_text is None:
        fail(f"未在 rollout 文件中找到 assistant output_text：{rollout_path}")
    return last_text.rstrip() + "\n"


session = json.loads(os.environ["SESSION_JSON"])
rollout_raw = session.get("rollout_path")
if not isinstance(rollout_raw, str) or not rollout_raw:
    fail("session JSON 缺少 rollout_path，无法读取最后一条消息。")

vault_dir = Path(os.environ["CODEX_OBSIDIAN_VAULT_DIR"]).expanduser().resolve()
preview_dir = Path(os.environ["CODEX_OBSIDIAN_PREVIEW_DIR"]).expanduser()
if not preview_dir.is_absolute():
    preview_dir = vault_dir / preview_dir
preview_dir = preview_dir.resolve()
preview_file = preview_dir / os.environ["CODEX_OBSIDIAN_PREVIEW_FILE"]

try:
    relative_path = preview_file.resolve().relative_to(vault_dir)
except ValueError:
    fail(f"预览文件必须位于 Obsidian vault 内：{preview_file}")

text = extract_text(Path(rollout_raw).expanduser())
preview_dir.mkdir(parents=True, exist_ok=True)
preview_file.write_text(text, encoding="utf-8")

print(
    json.dumps(
        {
            "file": str(preview_file),
            "obsidian_path": relative_path.as_posix(),
            "chars": len(text),
        },
        ensure_ascii=False,
    )
)
PY
)" || die "导出失败。"

obsidian_path="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["obsidian_path"])' <<<"$write_json")"

"$obsidian_bin" open "path=$obsidian_path" newtab "vault=$vault_name" >/dev/null 2>&1 || die "Obsidian 打开失败：$obsidian_path"
osascript -e 'tell application "Obsidian" to activate' >/dev/null 2>&1 || true
exit 0
