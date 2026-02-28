#!/usr/bin/env bash
# desc: Codex 绑定：保存所有 pane 的 codex 会话绑定到 state JSON
# usage: 在 M-p 面板选择；扫描当前 tmux server 全部 pane
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
if ! require_cmd python3; then
  die "找不到 python3。"
fi

session_probe="$HOME/.config/tmux/scripts/codex_session_id.py"
if [[ ! -f "$session_probe" ]]; then
  die "找不到脚本：$session_probe"
fi

state_dir="/Users/yoyo/.config/tmux/state"
state_file="$state_dir/codex-pane-bindings.json"
mkdir -p "$state_dir"

export SESSION_PROBE="$session_probe"
export STATE_FILE="$state_file"

result="$({
python3 <<'PY'
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile

session_probe = os.environ["SESSION_PROBE"]
state_file = os.environ["STATE_FILE"]

def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)

try:
    panes_raw = run([
        "tmux",
        "list-panes",
        "-a",
        "-F",
        "#{pane_id}\t#{pane_title}\t#{session_name}\t#{window_index}\t#{window_name}",
    ])
except Exception as exc:
    print(f"tmux list-panes 失败：{exc}", file=sys.stderr)
    raise SystemExit(2)

rows: list[dict[str, str]] = []
total = 0
for line in panes_raw.splitlines():
    if not line.strip():
        continue
    total += 1
    parts = line.split("\t")
    if len(parts) < 5:
        continue
    pane_id, pane_title, session_name, window_index, window_name = parts[:5]
    pane_title = pane_title.strip()
    if not pane_title:
        continue

    try:
        out = subprocess.check_output(
            ["python3", session_probe, "--pane", pane_id, "--json"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        out = ""

    if not out:
        continue

    try:
        payload = json.loads(out)
        session_id = payload.get("session_id")
    except Exception:
        session_id = None

    if not isinstance(session_id, str) or not session_id:
        continue

    rows.append(
        {
            "pane_id": pane_id,
            "pane_title": pane_title,
            "codex_session_id": session_id,
            "session_name": session_name,
            "window_index": str(window_index),
            "window_name": window_name,
            "saved_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        }
    )

state_dir = os.path.dirname(state_file)
os.makedirs(state_dir, exist_ok=True)
fd, tmp_path = tempfile.mkstemp(prefix="codex-pane-bindings.", suffix=".tmp", dir=state_dir)
os.close(fd)
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(rows, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp_path, state_file)

print(json.dumps({"total_panes": total, "saved": len(rows), "state_file": state_file}, ensure_ascii=False))
PY
} 2>&1)" || die "$result"

saved_count="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("saved",0))' <<<"$result" 2>/dev/null || echo 0)"
total_count="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("total_panes",0))' <<<"$result" 2>/dev/null || echo 0)"

printf '已保存 Codex 绑定：%s 条（扫描 pane：%s）\n' "$saved_count" "$total_count"
printf '文件：%s\n' "$state_file"
pause
