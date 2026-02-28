#!/usr/bin/env bash
# desc: Codex 绑定：按 pane title 恢复保存的 codex 会话绑定
# usage: 在 M-p 面板选择；按 pane_title 匹配并注入 cx resume 命令
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
report_file="$state_dir/codex-pane-bindings.restore.last.json"

if [[ ! -f "$state_file" ]]; then
  die "未找到状态文件：$state_file（请先执行“保存绑定关系”）。"
fi

export SESSION_PROBE="$session_probe"
export STATE_FILE="$state_file"
export REPORT_FILE="$report_file"

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
report_file = os.environ["REPORT_FILE"]

def sh(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )

def get_running_codex_session(pane_id: str) -> str | None:
    try:
        cp = sh(["python3", session_probe, "--pane", pane_id, "--json"], check=False)
    except Exception:
        return None
    out = (cp.stdout or "").strip()
    if cp.returncode != 0 or not out:
        return None
    try:
        payload = json.loads(out)
    except Exception:
        return None
    sid = payload.get("session_id")
    if isinstance(sid, str) and sid:
        return sid
    return None

try:
    with open(state_file, "r", encoding="utf-8") as f:
        saved = json.load(f)
except Exception as exc:
    print(f"读取状态文件失败：{exc}", file=sys.stderr)
    raise SystemExit(2)

if not isinstance(saved, list):
    print("状态文件格式错误：顶层必须是数组。", file=sys.stderr)
    raise SystemExit(2)

if not saved:
    report = {
        "restored_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "state_file": state_file,
        "total_records": 0,
        "success_count": 0,
        "skipped_count": 0,
        "items": [],
    }
    os.makedirs(os.path.dirname(report_file), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix="codex-pane-bindings.restore.", suffix=".tmp", dir=os.path.dirname(report_file))
    os.close(fd)
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp_path, report_file)
    print(json.dumps({"success": 0, "skipped": 0, "total": 0, "msg": "empty"}, ensure_ascii=False))
    raise SystemExit(0)

try:
    panes_cp = sh([
        "tmux",
        "list-panes",
        "-a",
        "-F",
        "#{pane_id}\t#{pane_title}\t#{session_name}\t#{window_index}\t#{window_name}",
    ])
except Exception as exc:
    print(f"tmux list-panes 失败：{exc}", file=sys.stderr)
    raise SystemExit(2)

live_panes: list[dict[str, str]] = []
for line in panes_cp.stdout.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 5:
        continue
    pane_id, pane_title, session_name, window_index, window_name = parts[:5]
    live_panes.append(
        {
            "pane_id": pane_id,
            "pane_title": pane_title.strip(),
            "session_name": session_name,
            "window_index": str(window_index),
            "window_name": window_name,
        }
    )

used_panes: set[str] = set()
items: list[dict[str, str]] = []
success_count = 0
skipped_count = 0

for entry in saved:
    if not isinstance(entry, dict):
        skipped_count += 1
        items.append({
            "status": "skipped",
            "reason": "invalid_record",
        })
        continue

    pane_title = str(entry.get("pane_title") or "").strip()
    target_session_id = str(entry.get("codex_session_id") or "").strip()
    saved_pane_id = str(entry.get("pane_id") or "").strip()

    if not pane_title:
        skipped_count += 1
        items.append(
            {
                "status": "skipped",
                "reason": "empty_pane_title",
                "saved_pane_id": saved_pane_id,
                "saved_session_id": target_session_id,
            }
        )
        continue

    if not target_session_id:
        skipped_count += 1
        items.append(
            {
                "status": "skipped",
                "reason": "empty_session_id",
                "saved_pane_id": saved_pane_id,
                "pane_title": pane_title,
            }
        )
        continue

    candidates = [
        pane
        for pane in live_panes
        if pane["pane_title"] == pane_title and pane["pane_id"] not in used_panes
    ]

    if not candidates:
        skipped_count += 1
        items.append(
            {
                "status": "skipped",
                "reason": "no_matching_pane_title",
                "pane_title": pane_title,
                "saved_pane_id": saved_pane_id,
                "saved_session_id": target_session_id,
            }
        )
        continue

    pane = candidates[0]
    pane_id = pane["pane_id"]
    used_panes.add(pane_id)

    running_sid = get_running_codex_session(pane_id)
    if running_sid:
        reason = "already_running_same_session" if running_sid == target_session_id else "conflict_running_codex"
        skipped_count += 1
        items.append(
            {
                "status": "skipped",
                "reason": reason,
                "pane_id": pane_id,
                "pane_title": pane_title,
                "saved_session_id": target_session_id,
                "running_session_id": running_sid,
            }
        )
        continue

    try:
        sh(["tmux", "send-keys", "-t", pane_id, "-X", "cancel"], check=False)
        sh(["tmux", "send-keys", "-t", pane_id, "-l", f"cx resume {target_session_id}"], check=True)
    except Exception as exc:
        skipped_count += 1
        items.append(
            {
                "status": "skipped",
                "reason": "send_keys_failed",
                "pane_id": pane_id,
                "pane_title": pane_title,
                "saved_session_id": target_session_id,
                "error": str(exc),
            }
        )
        continue

    success_count += 1
    items.append(
        {
            "status": "restored",
            "pane_id": pane_id,
            "pane_title": pane_title,
            "saved_session_id": target_session_id,
        }
    )

report = {
    "restored_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
    "state_file": state_file,
    "total_records": len(saved),
    "success_count": success_count,
    "skipped_count": skipped_count,
    "items": items,
}

os.makedirs(os.path.dirname(report_file), exist_ok=True)
fd, tmp_path = tempfile.mkstemp(prefix="codex-pane-bindings.restore.", suffix=".tmp", dir=os.path.dirname(report_file))
os.close(fd)
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp_path, report_file)

print(json.dumps({"success": success_count, "skipped": skipped_count, "total": len(saved), "report_file": report_file}, ensure_ascii=False))
PY
} 2>&1)" || die "$result"

success_count="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("success",0))' <<<"$result" 2>/dev/null || echo 0)"
skipped_count="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("skipped",0))' <<<"$result" 2>/dev/null || echo 0)"
total_count="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("total",0))' <<<"$result" 2>/dev/null || echo 0)"

if [[ "$total_count" == "0" ]]; then
  printf '无可恢复绑定（state 数组为空）。\n'
else
  printf '恢复完成：成功 %s / 跳过 %s / 总计 %s\n' "$success_count" "$skipped_count" "$total_count"
fi
printf '报告：%s\n' "$report_file"
pause
