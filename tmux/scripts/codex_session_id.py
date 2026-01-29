#!/usr/bin/env python3
"""
从 tmux pane 反推出正在运行的 Codex TUI 会话 ID（ConversationId/UUID）。

原理（基于 Codex 源码实现）：
- Codex 会话会写入 ~/.codex/sessions/YYYY/MM/DD/rollout-<local-ts>-<conversation_id>.jsonl
- 会话 id 就是文件名最后一段 UUID（也是 JSONL 首行 session_meta.payload.id）

做法：
1) tmux 获取 pane 的 shell 进程 pid（pane_pid）
2) 在该 pid 的子进程树里定位 codex 相关进程
3) 对候选 pid 用 lsof 找到打开的 rollout-*.jsonl
4) 取 mtime 最新的 rollout 文件，解析出 UUID 作为 session id
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, Optional


UUID_RE = re.compile(
    r"(?P<uuid>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"
)


def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)


def try_run(cmd: list[str]) -> Optional[str]:
    try:
        return run(cmd)
    except Exception:
        return None


def is_descendant(pid: int, ancestor_pid: int, parent_by_pid: dict[int, int], *, max_hops: int = 200) -> bool:
    cur = pid
    for _ in range(max_hops):
        if cur == ancestor_pid:
            return True
        cur = parent_by_pid.get(cur, 0)
        if cur <= 1:
            return False
    return False


@dataclass(frozen=True)
class Candidate:
    pid: int
    command: str


def iter_ps_table() -> tuple[dict[int, int], dict[int, str]]:
    out = run(["ps", "-axo", "pid=,ppid=,command="])
    parent_by_pid: dict[int, int] = {}
    command_by_pid: dict[int, str] = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid = int(parts[0])
        ppid = int(parts[1])
        cmd = parts[2]
        parent_by_pid[pid] = ppid
        command_by_pid[pid] = cmd
    return parent_by_pid, command_by_pid


def iter_codex_candidates(command_by_pid: dict[int, str]) -> Iterable[Candidate]:
    patterns = [
        # Rust vendor binary (macOS / Volta install shape)
        re.compile(r"/@openai/codex/.*/vendor/.*/codex/codex\b"),
        # Node wrapper that boots the vendor binary
        re.compile(r"/@openai/codex/bin/codex\b"),
        # Fallback: bare `codex` command
        re.compile(r"(^|[\s/])codex([\s]|$)"),
    ]
    for pid, cmd in command_by_pid.items():
        if any(p.search(cmd) for p in patterns):
            yield Candidate(pid=pid, command=cmd)


def rollout_paths_open_by_pid(pid: int) -> list[str]:
    # 用 -F 避免路径里有空格时 split 出错；n<path> 字段是文件名
    out = try_run(["lsof", "-p", str(pid), "-Fn"])
    if not out:
        return []
    paths: list[str] = []
    for line in out.splitlines():
        if not line.startswith("n"):
            continue
        path = line[1:]
        if "/.codex/sessions/" not in path:
            continue
        if "rollout-" not in path or not path.endswith(".jsonl"):
            continue
        paths.append(path)
    # 去重保持顺序
    dedup: list[str] = []
    seen: set[str] = set()
    for p in paths:
        if p in seen:
            continue
        seen.add(p)
        dedup.append(p)
    return dedup


def parse_session_id_from_rollout_path(path: str) -> str:
    m = UUID_RE.search(path)
    if not m:
        raise ValueError(f"无法从 rollout 路径解析 UUID: {path}")
    # filename 里会出现很多 '-'，取最后一个 UUID（conversation_id）更稳
    all_ids = UUID_RE.findall(path)
    return all_ids[-1]


def latest_mtime_path(paths: list[str]) -> str:
    def mtime(p: str) -> float:
        return os.stat(p).st_mtime

    existing: list[str] = []
    for p in paths:
        try:
            os.stat(p)
        except FileNotFoundError:
            continue
        existing.append(p)
    if not existing:
        raise FileNotFoundError("rollout 文件不存在（可能已被清理）")
    return max(existing, key=mtime)


def get_pane_pid(pane: str) -> int:
    out = run(["tmux", "display-message", "-p", "-t", pane, "#{pane_pid}"]).strip()
    return int(out)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pane", help="tmux pane id，例如 %%410；默认读取 $TMUX_PANE")
    ap.add_argument("--json", action="store_true", help="输出 JSON（包含 rollout_path 等信息）")
    ap.add_argument("--print-path", action="store_true", help="额外打印 rollout 文件路径（非 JSON 模式）")
    args = ap.parse_args(argv)

    pane = args.pane or os.environ.get("TMUX_PANE")
    if not pane:
        print("缺少 --pane 且未设置 $TMUX_PANE", file=sys.stderr)
        return 2

    pane_pid = get_pane_pid(pane)
    parent_by_pid, command_by_pid = iter_ps_table()

    candidate_rollouts: list[str] = []
    matched_pids: list[int] = []

    for cand in iter_codex_candidates(command_by_pid):
        if not is_descendant(cand.pid, pane_pid, parent_by_pid):
            continue
        matched_pids.append(cand.pid)
        candidate_rollouts.extend(rollout_paths_open_by_pid(cand.pid))

    if not candidate_rollouts:
        print(f"未在 pane {pane} (pane_pid={pane_pid}) 的 codex 进程中发现 rollout-*.jsonl", file=sys.stderr)
        if matched_pids:
            print(f"已匹配到的 codex 相关 pid: {sorted(set(matched_pids))}", file=sys.stderr)
        return 3

    rollout_path = latest_mtime_path(sorted(set(candidate_rollouts)))
    session_id = parse_session_id_from_rollout_path(rollout_path)

    if args.json:
        payload = {
            "pane": pane,
            "pane_pid": pane_pid,
            "session_id": session_id,
            "rollout_path": rollout_path,
            "matched_pids": sorted(set(matched_pids)),
        }
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    print(session_id)
    if args.print_path:
        print(rollout_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
