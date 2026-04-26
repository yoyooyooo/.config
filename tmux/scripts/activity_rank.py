#!/usr/bin/env python3
"""Rank tmux sessions, windows, and panes by actionable activity."""

from __future__ import annotations

from dataclasses import dataclass
import os
import re
import subprocess
import sys
from typing import Iterable


DEFAULT_AGENT_RE = (
    r"(^|[^A-Za-z0-9_])"
    r"(codex|claude|gemini|opencode|aider|goose|cursor-agent|cursor agent|"
    r"roo|cline|openai|anthropic)"
    r"([^A-Za-z0-9_]|$)"
)
DEFAULT_NOISE_RE = (
    r"(^|[^A-Za-z0-9_])"
    r"(vite|vite-node|webpack|webpack-dev-server|next dev|next-server|"
    r"storybook|tsc -w|tsc --watch|nodemon|tsx watch|npm run dev|"
    r"pnpm dev|pnpm run dev|yarn dev|bun dev|nuxt|astro|svelte-kit|"
    r"turbo dev|rollup -w|rollup --watch|parcel)"
    r"([^A-Za-z0-9_]|$)"
)


@dataclass
class WindowRow:
    session_id: str
    session_name: str
    window_id: str
    window_index: int
    window_name: str
    activity: int
    activity_flag: bool
    codex_done: bool
    active: bool
    zoomed: bool = False


@dataclass
class SessionRow:
    session_id: str
    session_name: str
    activity: int


@dataclass
class PaneRow:
    window_id: str
    pane_id: str
    pane_index: int
    command: str
    title: str
    path: str
    pane_pid: int


@dataclass
class PaneDetail:
    session_id: str
    session_name: str
    window_id: str
    window_index: int
    window_name: str
    pane_id: str
    pane_index: int
    command: str
    title: str
    path: str
    window_activity: int
    window_activity_flag: bool
    codex_done: bool
    window_active: bool
    window_zoomed: bool
    pane_pid: int = 0
    pane_active: bool = False


def _rx(name: str, default: str) -> re.Pattern[str]:
    return re.compile(os.environ.get(name, default), re.IGNORECASE)


AGENT_RE = _rx("TMUX_ACTIVITY_AGENT_RE", DEFAULT_AGENT_RE)
NOISE_RE = _rx("TMUX_ACTIVITY_NOISE_RE", DEFAULT_NOISE_RE)


def _as_bool(value: str | bool | int | None) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    return str(value or "").strip().lower() in {"1", "on", "true", "yes"}


def _as_int(value: str | int | None) -> int:
    try:
        return int(str(value or "0").strip())
    except ValueError:
        return 0


def _norm(text: str) -> str:
    return " ".join((text or "").replace("\t", " ").split()).lower()


def _process_table() -> tuple[dict[int, list[int]], dict[int, str]]:
    try:
        raw = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return {}, {}

    children: dict[int, list[int]] = {}
    commands: dict[int, str] = {}
    for line in raw.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        command = parts[2] if len(parts) > 2 else ""
        commands[pid] = command
        children.setdefault(ppid, []).append(pid)
    return children, commands


def _descendant_text_for(pids: Iterable[int]) -> dict[int, str]:
    children, commands = _process_table()
    out: dict[int, str] = {}
    for root in pids:
        if not root:
            out[root] = ""
            continue
        seen: set[int] = set()
        stack = [root]
        parts: list[str] = []
        while stack and len(seen) < 80:
            pid = stack.pop()
            if pid in seen:
                continue
            seen.add(pid)
            if pid in commands:
                parts.append(commands[pid])
            stack.extend(children.get(pid, []))
        out[root] = _norm(" ".join(parts))
    return out


def _pane_direct_text(pane: PaneRow | PaneDetail) -> str:
    return _norm(f"{pane.command} {pane.title}")


def _pane_process_text(pane: PaneRow | PaneDetail, process_text: dict[object, str]) -> str:
    proc = process_text.get(getattr(pane, "pane_id", ""), "")
    if not proc:
        proc = process_text.get(getattr(pane, "pane_pid", 0), "")
    return _norm(proc)


def _pane_text(pane: PaneRow | PaneDetail, process_text: dict[object, str]) -> str:
    return _norm(f"{_pane_direct_text(pane)} {_pane_process_text(pane, process_text)}")


def _pane_kind(pane: PaneRow | PaneDetail, process_text: dict[object, str]) -> str:
    direct = _pane_direct_text(pane)
    if AGENT_RE.search(direct):
        return "agent"
    text = _norm(f"{direct} {_pane_process_text(pane, process_text)}")
    if AGENT_RE.search(text):
        return "agent"
    if NOISE_RE.search(text):
        return "noise"
    return "normal"


def _window_kind(window: WindowRow, panes: list[PaneRow], process_text: dict[object, str]) -> str:
    if window.codex_done:
        return "done"
    kinds = [_pane_kind(pane, process_text) for pane in panes]
    if kinds and all(kind == "noise" for kind in kinds):
        return "noise"
    if "agent" in kinds:
        return "agent"
    return "normal"


def _rank_for_window(window: WindowRow, panes: list[PaneRow], process_text: dict[object, str]) -> tuple[int, int, int, int, str]:
    kind = _window_kind(window, panes, process_text)
    # Keep tmux's raw activity flag as a marker, not a primary rank bucket:
    # long-running dev servers can set it forever, while window_activity is the useful freshness signal.
    if kind == "done":
        bucket = 0
        mark = "✓"
    elif kind == "noise":
        bucket = 2
        mark = "·"
    else:
        bucket = 1
        if kind == "agent" and window.activity_flag:
            mark = "●"
        elif window.activity_flag:
            mark = "•"
        else:
            mark = " "
    setattr(window, "kind", kind)
    setattr(window, "bucket", bucket)
    setattr(window, "mark", mark)
    return (bucket, -window.activity, 0 if window.active else 1, window.window_index, window.window_id)


def rank_windows(windows: list[WindowRow], panes: list[PaneRow], process_text: dict[object, str]) -> list[WindowRow]:
    panes_by_window: dict[str, list[PaneRow]] = {}
    for pane in panes:
        panes_by_window.setdefault(pane.window_id, []).append(pane)
    return sorted(windows, key=lambda row: _rank_for_window(row, panes_by_window.get(row.window_id, []), process_text))


def rank_sessions(
    sessions: list[SessionRow],
    windows: list[WindowRow],
    panes: list[PaneRow],
    process_text: dict[object, str],
) -> list[SessionRow]:
    ranked_windows = rank_windows(windows, panes, process_text)
    best_by_session: dict[str, WindowRow] = {}
    for window in ranked_windows:
        current = best_by_session.get(window.session_id)
        if current is None:
            best_by_session[window.session_id] = window
            continue
        if (getattr(window, "bucket", 9), -window.activity) < (getattr(current, "bucket", 9), -current.activity):
            best_by_session[window.session_id] = window

    def key(session: SessionRow) -> tuple[int, int, str]:
        best = best_by_session.get(session.session_id)
        if best is None:
            setattr(session, "mark", " ")
            setattr(session, "bucket", 3)
            return (3, -session.activity, session.session_name)
        setattr(session, "mark", getattr(best, "mark", " "))
        setattr(session, "bucket", getattr(best, "bucket", 3))
        return (getattr(best, "bucket", 3), -best.activity, session.session_name)

    return sorted(sessions, key=key)


def rank_panes(
    panes: list[PaneDetail],
    process_text: dict[object, str],
    origin_pane_id: str = "",
) -> list[PaneDetail]:
    windows: dict[str, WindowRow] = {}
    pane_rows: list[PaneRow] = []
    for pane in panes:
        windows[pane.window_id] = WindowRow(
            pane.session_id,
            pane.session_name,
            pane.window_id,
            pane.window_index,
            pane.window_name,
            pane.window_activity,
            pane.window_activity_flag,
            pane.codex_done,
            pane.window_active,
            pane.window_zoomed,
        )
        pane_rows.append(
            PaneRow(
                pane.window_id,
                pane.pane_id,
                pane.pane_index,
                pane.command,
                pane.title,
                pane.path,
                pane.pane_pid,
            )
        )
    ranked_windows = rank_windows(list(windows.values()), pane_rows, process_text)
    window_rank = {row.window_id: (getattr(row, "bucket", 3), -row.activity, row.window_index, getattr(row, "mark", " ")) for row in ranked_windows}

    def key(pane: PaneDetail) -> tuple[int, int, int, int, str]:
        bucket, neg_activity, window_index, mark = window_rank.get(pane.window_id, (3, -pane.window_activity, pane.window_index, " "))
        kind = _pane_kind(pane, process_text)
        pane_penalty = 1 if kind == "noise" and bucket != 4 else 0
        setattr(pane, "mark", mark if bucket != 4 else "·")
        setattr(pane, "kind", kind)
        return (bucket, neg_activity, window_index, pane_penalty, pane.pane_id)

    return sorted(panes, key=key)


def _tmux_cmd(args: list[str]) -> list[str]:
    socket = os.environ.get("OUTER_TMUX_SOCKET") or os.environ.get("TMUX_ACTIVITY_SOCKET")
    if socket:
        return ["tmux", "-S", socket, *args]
    return ["tmux", *args]


def _tmux_out(args: list[str]) -> str:
    return subprocess.check_output(_tmux_cmd(args), text=True, stderr=subprocess.DEVNULL)


def _tmux_set(args: list[str]) -> None:
    try:
        subprocess.run(_tmux_cmd(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception:
        pass


def _split_rows(raw: str) -> Iterable[list[str]]:
    for line in raw.splitlines():
        if line.strip():
            yield line.split("\t")


def collect_windows() -> list[WindowRow]:
    fmt = "#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{window_activity}\t#{window_activity_flag}\t#{@codex_done}\t#{window_active}\t#{window_zoomed_flag}"
    rows: list[WindowRow] = []
    for parts in _split_rows(_tmux_out(["list-windows", "-a", "-F", fmt])):
        parts += [""] * (10 - len(parts))
        rows.append(WindowRow(parts[0], parts[1], parts[2], _as_int(parts[3]), parts[4], _as_int(parts[5]), _as_bool(parts[6]), _as_bool(parts[7]), _as_bool(parts[8]), _as_bool(parts[9])))
    return rows


def collect_sessions() -> list[SessionRow]:
    fmt = "#{session_id}\t#{session_name}\t#{session_activity}"
    rows: list[SessionRow] = []
    for parts in _split_rows(_tmux_out(["list-sessions", "-F", fmt])):
        parts += [""] * (3 - len(parts))
        rows.append(SessionRow(parts[0], parts[1], _as_int(parts[2])))
    return rows


def collect_pane_rows() -> list[PaneRow]:
    fmt = "#{window_id}\t#{pane_id}\t#{pane_index}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}\t#{pane_pid}"
    rows: list[PaneRow] = []
    for parts in _split_rows(_tmux_out(["list-panes", "-a", "-F", fmt])):
        parts += [""] * (7 - len(parts))
        rows.append(PaneRow(parts[0], parts[1], _as_int(parts[2]), parts[3], parts[4], parts[5], _as_int(parts[6])))
    return rows


def collect_pane_details() -> list[PaneDetail]:
    fmt = "#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_id}\t#{pane_index}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}\t#{window_activity}\t#{window_activity_flag}\t#{@codex_done}\t#{window_active}\t#{window_zoomed_flag}\t#{pane_pid}\t#{pane_active}"
    rows: list[PaneDetail] = []
    exclude_window = _tmux_out(["show", "-gqv", "@fzf_exclude_window_id"]).strip()
    origin = os.environ.get("ORIGIN_PANE_ID", "").strip()
    if not origin:
        origin = _tmux_out(["show", "-gqv", "@panes_popup_origin_pane_id"]).strip()
    for parts in _split_rows(_tmux_out(["list-panes", "-a", "-F", fmt])):
        parts += [""] * (17 - len(parts))
        if exclude_window and parts[2] == exclude_window and parts[5] != origin:
            continue
        rows.append(
            PaneDetail(
                parts[0], parts[1], parts[2], _as_int(parts[3]), parts[4],
                parts[5], _as_int(parts[6]), parts[7], parts[8], parts[9],
                _as_int(parts[10]), _as_bool(parts[11]), _as_bool(parts[12]),
                _as_bool(parts[13]), _as_bool(parts[14]), _as_int(parts[15]),
                _as_bool(parts[16]),
            )
        )
    return rows


def process_text_for_panes(panes: Iterable[PaneRow | PaneDetail]) -> dict[object, str]:
    rows = list(panes)
    by_pid = _descendant_text_for([getattr(row, "pane_pid", 0) for row in rows])
    out: dict[object, str] = dict(by_pid)
    for row in rows:
        out[getattr(row, "pane_id", "")] = by_pid.get(getattr(row, "pane_pid", 0), "")
    return out


def print_windows() -> None:
    windows = collect_windows()
    panes = collect_pane_rows()
    process_text = process_text_for_panes(panes)
    for row in rank_windows(windows, panes, process_text):
        zoom = "⛶" if row.zoomed else " "
        active = "▶" if row.active else " "
        label = f"{getattr(row, 'mark', ' ')}{zoom}{active} {row.session_name}:{row.window_index}  {row.window_name}"
        print(f"{row.session_name}:{row.window_index}\t{label}")


def print_sessions() -> None:
    sessions = collect_sessions()
    windows = collect_windows()
    panes = collect_pane_rows()
    process_text = process_text_for_panes(panes)
    for row in rank_sessions(sessions, windows, panes, process_text):
        print(f"{row.session_name}\t{getattr(row, 'mark', ' ')} {row.session_name}")


def print_panes() -> None:
    panes = collect_pane_details()
    process_text = process_text_for_panes(panes)
    ranked = rank_panes(panes, process_text, os.environ.get("ORIGIN_PANE_ID", ""))
    print("PANEID\tSESSION_ID\tWINDOW_ID\tSESSION\tWIN\tPANE\tTITLE\tCMD\tPATH")
    for row in ranked:
        zoom = "⛶" if row.window_zoomed else " "
        active = "▶" if row.window_active else " "
        win = f"{getattr(row, 'mark', ' ')}{zoom}{active} {row.window_index}:{row.window_name}"
        print(f"{row.pane_id}\t{row.session_id}\t{row.window_id}\t{row.session_name}\t{win}\t{row.pane_index}\t{row.title}\t{row.command}\t{row.path}")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: activity_rank.py windows|sessions|panes", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "windows":
        print_windows()
    elif cmd == "sessions":
        print_sessions()
    elif cmd == "panes":
        print_panes()
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
