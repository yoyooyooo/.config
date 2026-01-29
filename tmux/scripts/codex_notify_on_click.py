#!/usr/bin/env python3
import argparse
import os
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass


TMUX_TIMEOUT_SECONDS = 1.0
HUD_TIMEOUT_SECONDS = 2.0
ITERM2_TIMEOUT_SECONDS = 1.5
OSASCRIPT_BIN = "/usr/bin/osascript"
BTT_HUD_SCRIPT = os.path.expanduser("~/.config/tmux/scripts/tmux_btt_hud_notify.sh")


@dataclass(frozen=True)
class TmuxClient:
    name: str
    tty: str | None


@dataclass(frozen=True)
class TmuxSession:
    id: str
    name: str


def _shell_join(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv)


def _run(
    argv: list[str],
    *,
    timeout: float,
    check: bool,
    capture_stdout: bool,
) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            argv,
            check=check,
            stdout=subprocess.PIPE if capture_stdout else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def _find_tmux() -> str | None:
    candidates = [
        shutil.which("tmux"),
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _tmux_argv(tmux_bin: str, socket: str | None, args: list[str]) -> list[str]:
    argv = [tmux_bin]
    if socket:
        argv.extend(["-S", socket])
    argv.extend(args)
    return argv


def _tmux_capture(tmux_bin: str, socket: str | None, args: list[str]) -> str | None:
    result = _run(
        _tmux_argv(tmux_bin, socket, args),
        timeout=TMUX_TIMEOUT_SECONDS,
        check=True,
        capture_stdout=True,
    )
    if not result:
        return None
    value = (result.stdout or "").strip()
    return value or None


def _tmux_ok(tmux_bin: str, socket: str | None, args: list[str]) -> bool:
    result = _run(
        _tmux_argv(tmux_bin, socket, args),
        timeout=TMUX_TIMEOUT_SECONDS,
        check=True,
        capture_stdout=False,
    )
    return bool(result)


def _tmux_display(tmux_bin: str, socket: str | None, target: str | None, fmt: str) -> str | None:
    args = ["display-message", "-p"]
    if target:
        args.extend(["-t", target])
    args.append(fmt)
    return _tmux_capture(tmux_bin, socket, args)


def _tmux_list_clients(tmux_bin: str, socket: str | None) -> list[TmuxClient]:
    raw = _tmux_capture(tmux_bin, socket, ["list-clients", "-F", "#{client_name}\t#{client_tty}"])
    if not raw:
        return []
    clients: list[TmuxClient] = []
    for line in raw.splitlines():
        name, _, tty = line.partition("\t")
        name = name.strip()
        tty = tty.strip()
        if not name:
            continue
        clients.append(TmuxClient(name=name, tty=tty or None))
    return clients


def _resolve_client(
    *,
    requested_name: str | None,
    requested_tty: str | None,
    connected: list[TmuxClient],
) -> TmuxClient | None:
    if requested_name:
        for client in connected:
            if client.name == requested_name:
                return client
    if requested_tty:
        for client in connected:
            if client.tty == requested_tty:
                return client
    if len(connected) == 1:
        return connected[0]
    return None


def _tmux_pane_exists(tmux_bin: str, socket: str | None, pane_id: str) -> bool:
    return bool(_tmux_display(tmux_bin, socket, pane_id, "#{pane_id}"))


def _tmux_sessions_for_window(tmux_bin: str, socket: str | None, window_id: str) -> list[TmuxSession]:
    raw = _tmux_capture(tmux_bin, socket, ["list-windows", "-a", "-F", "#{session_id}\t#{session_name}\t#{window_id}"])
    if not raw:
        return []
    sessions: list[TmuxSession] = []
    seen: set[str] = set()
    for line in raw.splitlines():
        session_id, _, rest = line.partition("\t")
        session_name, _, win_id = rest.partition("\t")
        session_id = session_id.strip()
        session_name = session_name.strip()
        win_id = win_id.strip()
        if not session_id or not session_name or not win_id:
            continue
        if win_id != window_id:
            continue
        if session_id in seen:
            continue
        seen.add(session_id)
        sessions.append(TmuxSession(id=session_id, name=session_name))
    return sessions


def _choose_session(
    candidates: list[TmuxSession],
    *,
    preferred_id: str | None,
    preferred_name: str | None,
) -> tuple[TmuxSession | None, str | None]:
    if not candidates:
        return None, "未找到包含该 window 的 session"
    if preferred_id:
        for sess in candidates:
            if sess.id == preferred_id:
                return sess, None
    if preferred_name:
        for sess in candidates:
            if sess.name == preferred_name:
                return sess, None
    if len(candidates) == 1:
        return candidates[0], None
    return None, "该 window 同时属于多个 session，且无法确定原始 session"


def _hud(title: str, body: str, *, client_tty: str | None) -> None:
    if os.path.isfile(BTT_HUD_SCRIPT) and os.access(BTT_HUD_SCRIPT, os.X_OK):
        _run(
            [BTT_HUD_SCRIPT, title, body, client_tty or ""],
            timeout=HUD_TIMEOUT_SECONDS,
            check=False,
            capture_stdout=False,
        )
        return

    applescript = (
        "on run argv\n"
        "  display notification (item 2 of argv) with title (item 1 of argv)\n"
        "end run\n"
    )
    _run(
        [OSASCRIPT_BIN, "-e", applescript, title, body],
        timeout=HUD_TIMEOUT_SECONDS,
        check=False,
        capture_stdout=False,
    )


def _iterm2_select_session_by_tty(target_tty: str) -> bool:
    if sys.platform != "darwin":
        return False

    tty = target_tty.strip()
    if not tty:
        return False

    applescript = """
on run argv
  set targetTty to item 1 of argv
  tell application "iTerm2"
    set found to false
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          try
            if (tty of s) is equal to targetTty then
              set found to true
              try
                if is hotkey window of w then
                  tell w to reveal hotkey window
                else
                  tell w to select
                end if
              end try
              try
                tell t to select
              end try
              try
                tell s to select
              end try
              activate
              return "1"
            end if
          end try
        end repeat
        if found then exit repeat
      end repeat
      if found then exit repeat
    end repeat
  end tell
  return ""
end run
""".strip()

    result = _run(
        [OSASCRIPT_BIN, "-e", applescript, tty],
        timeout=ITERM2_TIMEOUT_SECONDS,
        check=False,
        capture_stdout=True,
    )
    if not result or result.returncode != 0:
        return False
    return bool((result.stdout or "").strip())


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--tmux-bin")
    parser.add_argument("--tmux-socket")
    parser.add_argument("--client")
    parser.add_argument("--client-tty")
    parser.add_argument("--session-id")
    parser.add_argument("--session-name")
    parser.add_argument("--window-id")
    parser.add_argument("--window-name")
    parser.add_argument("--pane-id")
    parser.add_argument("--cwd")
    parser.add_argument("--notification-title")
    parser.add_argument("--dry-run", action="store_true")
    args, _unknown = parser.parse_known_args(argv[1:])

    tmux_bin = args.tmux_bin or _find_tmux()
    if not tmux_bin:
        _hud(args.notification_title or "Codex", "回跳失败：找不到 tmux 命令", client_tty=args.client_tty)
        return 0

    socket = (args.tmux_socket or "").strip() or None

    clients = _tmux_list_clients(tmux_bin, socket)
    resolved_client = _resolve_client(
        requested_name=(args.client or "").strip() or None,
        requested_tty=(args.client_tty or "").strip() or None,
        connected=clients,
    )
    if not resolved_client:
        connected_desc = "，".join(
            f"{c.name}({c.tty})" if c.tty else c.name
            for c in clients
        ) or "无"
        _hud(
            args.notification_title or "Codex",
            f"回跳失败：找不到对应 tmux client\n已连接：{connected_desc}",
            client_tty=args.client_tty,
        )
        return 0

    focus_tty = (args.client_tty or "").strip() or resolved_client.tty or ""
    focused_iterm2 = _iterm2_select_session_by_tty(focus_tty) if focus_tty else False

    pane_id = (args.pane_id or "").strip() or None
    if pane_id and not _tmux_pane_exists(tmux_bin, socket, pane_id):
        pane_id = None

    window_id = (args.window_id or "").strip() or None
    if pane_id:
        window_id = _tmux_display(tmux_bin, socket, pane_id, "#{window_id}") or window_id

    if not window_id:
        _hud(
            args.notification_title or "Codex",
            "回跳失败：缺少 window/pane 信息，无法定位目标",
            client_tty=args.client_tty,
        )
        return 0

    session_candidates = _tmux_sessions_for_window(tmux_bin, socket, window_id)
    chosen_session, session_reason = _choose_session(
        session_candidates,
        preferred_id=(args.session_id or "").strip() or None,
        preferred_name=(args.session_name or "").strip() or None,
    )
    if not chosen_session:
        candidates_desc = "，".join(f"{s.name}({s.id})" for s in session_candidates) or "无"
        details = f"回跳失败：{session_reason}\n候选：{candidates_desc}"
        _hud(args.notification_title or "Codex", details, client_tty=args.client_tty)
        return 0

    target_session = chosen_session.id

    commands: list[list[str]] = []
    commands.append(["switch-client", "-c", resolved_client.name, "-t", target_session])
    commands.append(["select-window", "-t", f"{resolved_client.name}:{window_id}"])
    if pane_id:
        commands.append(["select-pane", "-t", pane_id])

    if args.dry_run:
        for cmd in commands:
            print(_shell_join(_tmux_argv(tmux_bin, socket, cmd)))
        return 0

    failures: list[str] = []
    for cmd in commands:
        if not _tmux_ok(tmux_bin, socket, cmd):
            failures.append(_shell_join(cmd))

    if failures:
        where = []
        if args.session_name or args.session_id:
            where.append(f"session={args.session_name or args.session_id}")
        if args.window_name or args.window_id:
            where.append(f"window={args.window_name or args.window_id}")
        if args.pane_id:
            where.append(f"pane={args.pane_id}")
        where_desc = " ".join(where) if where else "未知"
        _hud(
            args.notification_title or "Codex",
            "回跳失败：tmux 命令执行失败\n"
            f"目标：{where_desc}\n"
            f"失败：{'; '.join(failures)}",
            client_tty=args.client_tty,
        )
        return 0

    if sys.platform == "darwin" and focus_tty and not focused_iterm2:
        _hud(
            args.notification_title or "Codex",
            f"回跳提示：tmux 已切换，但未能在 iTerm2 中定位对应 tab/session（tty={focus_tty}）",
            client_tty=args.client_tty,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
