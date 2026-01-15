#!/usr/bin/env python3
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from typing import Any


MAX_MESSAGE_CHARS = 220
GIT_TIMEOUT_SECONDS = 1.0
TMUX_TIMEOUT_SECONDS = 1.0
OSASCRIPT_TIMEOUT_SECONDS = 0.8
ITERM2_BUNDLE_ID = "com.googlecode.iterm2"
ON_CLICK_SCRIPT = os.path.join(os.path.dirname(__file__), "codex_notify_on_click.py")
TMUX_TURN_COMPLETE_DIR = os.path.expanduser(
    os.environ.get("CODEX_TMUX_TURN_COMPLETE_DIR", "~/.config/tmux/run/codex-turn-complete")
)


def _normalize(text: str) -> str:
    return " ".join(text.split())


def _truncate(text: str, limit: int) -> str:
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 3)] + "..."


def _shell_join(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv)


def _find_terminal_notifier() -> str | None:
    candidates = [
        shutil.which("terminal-notifier"),
        "/opt/homebrew/bin/terminal-notifier",
        "/usr/local/bin/terminal-notifier",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
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


def _tmux_socket_from_env() -> str | None:
    tmux = os.environ.get("TMUX", "").strip()
    if not tmux:
        return None
    socket, _, _rest = tmux.partition(",")
    socket = socket.strip()
    return socket or None


def _tmux_ok(tmux_bin: str, socket: str | None, args: list[str]) -> bool:
    argv = [tmux_bin]
    if socket:
        argv.extend(["-S", socket])
    argv.extend(args)
    try:
        result = subprocess.run(
            argv,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=TMUX_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _tmux_display(tmux_bin: str, socket: str | None, message: str, *, target: str | None = None) -> str | None:
    argv = [tmux_bin]
    if socket:
        argv.extend(["-S", socket])
    argv.extend(["display-message", "-p"])
    if target:
        argv.extend(["-t", target])
    argv.append(message)
    try:
        result = subprocess.run(
            argv,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=TMUX_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    value = (result.stdout or "").strip()
    return value or None


def _tmux_capture(tmux_bin: str, socket: str | None, args: list[str]) -> str | None:
    argv = [tmux_bin]
    if socket:
        argv.extend(["-S", socket])
    argv.extend(args)
    try:
        result = subprocess.run(
            argv,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=TMUX_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    value = (result.stdout or "").strip()
    return value or None


def _frontmost_bundle_id() -> str | None:
    try:
        result = subprocess.run(
            [
                "osascript",
                "-e",
                'tell application "System Events" to get bundle identifier of first application process whose frontmost is true',
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=OSASCRIPT_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    value = (result.stdout or "").strip()
    return value or None


def _tmux_pane_is_active_in_any_client(tmux_bin: str, socket: str | None, pane_id: str) -> bool:
    if not pane_id:
        return False
    out = _tmux_capture(tmux_bin, socket, ["list-clients", "-F", "#{pane_id}"])
    if not out:
        return False
    for line in out.splitlines():
        if line.strip() == pane_id:
            return True
    return False


def _tmux_pane_is_focused_in_any_client(tmux_bin: str, socket: str | None, pane_id: str) -> bool:
    if not pane_id:
        return False
    out = _tmux_capture(tmux_bin, socket, ["list-clients", "-F", "#{client_flags}\t#{pane_id}"])
    if not out:
        return False
    for line in out.splitlines():
        if "\t" in line:
            flags, client_pane_id = line.split("\t", 1)
        else:
            flags, client_pane_id = "", line
        if client_pane_id.strip() != pane_id:
            continue
        flag_set = {part.strip() for part in flags.split(",") if part.strip()}
        if "focused" in flag_set:
            return True
    return False


def _tmux_client_count(tmux_bin: str, socket: str | None) -> int:
    out = _tmux_capture(tmux_bin, socket, ["list-clients", "-F", "#{client_name}"])
    if not out:
        return 0
    return sum(1 for line in out.splitlines() if line.strip())


def _safe_filename(value: str) -> str:
    value = (value or "").strip()
    if not value:
        return "unknown"
    value = value.replace("/", "_").replace(":", "_")
    while ".." in value:
        value = value.replace("..", "__")
    return value


def _write_turn_complete_marker(*, thread_id: str, turn_id: str, cwd: str, title: str, message: str) -> None:
    pane_id = os.environ.get("TMUX_PANE", "").strip()
    if not pane_id:
        return

    tmux_bin = _find_tmux()
    if not tmux_bin:
        return

    socket = _tmux_socket_from_env()
    if _tmux_pane_is_focused_in_any_client(tmux_bin, socket, pane_id):
        return

    window_id = _tmux_display(tmux_bin, socket, "#{window_id}", target=pane_id) or ""
    server_pid = _tmux_display(tmux_bin, socket, "#{pid}") or ""

    try:
        os.makedirs(TMUX_TURN_COMPLETE_DIR, exist_ok=True)
    except Exception:
        return

    path = os.path.join(TMUX_TURN_COMPLETE_DIR, _safe_filename(pane_id))
    tmp_path = f"{path}.tmp"
    payload = {
        "type": "agent-turn-complete",
        "thread-id": thread_id,
        "turn-id": turn_id,
        "cwd": cwd,
        "title": title,
        "message": message,
        "tmux-server-pid": server_pid,
        "pane-id": pane_id,
        "window-id": window_id,
        "created-at": int(time.time()),
    }
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return

    if window_id:
        _tmux_ok(tmux_bin, socket, ["set-window-option", "-t", window_id, "@codex_done", "1"])


def _gc_turn_complete_markers(*, current_server_pid: str) -> None:
    if not current_server_pid:
        return
    ttl_raw = os.environ.get("CODEX_TMUX_TURN_COMPLETE_TTL_SECONDS", "").strip()
    ttl_seconds = 0
    if ttl_raw:
        try:
            ttl_seconds = int(float(ttl_raw))
        except ValueError:
            ttl_seconds = 0
    if ttl_seconds < 0:
        ttl_seconds = 0

    tmux_bin = _find_tmux()
    socket = _tmux_socket_from_env()
    pane_ids: set[str] | None = None
    if tmux_bin:
        out = _tmux_capture(tmux_bin, socket, ["list-panes", "-a", "-F", "#{pane_id}"])
        if out:
            pane_ids = {line.strip() for line in out.splitlines() if line.strip()}

    try:
        entries = os.listdir(TMUX_TURN_COMPLETE_DIR)
    except Exception:
        return
    count = 0
    for name in entries:
        if not name or name.startswith("."):
            continue
        path = os.path.join(TMUX_TURN_COMPLETE_DIR, name)
        if not os.path.isfile(path):
            continue

        # Best-effort: derive a pane_id candidate from the filename.
        pane_id_from_name = name if name.startswith("%") else ""

        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = None

        # If the marker points to a pane that no longer exists, we can safely delete it.
        if pane_ids is not None and pane_id_from_name and pane_id_from_name not in pane_ids:
            try:
                os.unlink(path)
            except OSError:
                pass
            continue

        if isinstance(data, dict):
            marker_server_pid = data.get("tmux-server-pid")
            if isinstance(marker_server_pid, str) and marker_server_pid and marker_server_pid != current_server_pid:
                try:
                    os.unlink(path)
                except OSError:
                    pass
                continue

            if ttl_seconds > 0:
                created_at = data.get("created-at")
                if not isinstance(created_at, int):
                    created_at = 0
                if created_at > 0 and (time.time() - float(created_at)) > float(ttl_seconds):
                    try:
                        os.unlink(path)
                    except OSError:
                        pass
                    continue
        elif ttl_seconds > 0:
            # Unknown marker format: fall back to file mtime TTL.
            try:
                st = os.stat(path)
                if (time.time() - float(st.st_mtime)) > float(ttl_seconds):
                    os.unlink(path)
                    continue
            except OSError:
                pass

        count += 1
        if count >= 200:
            break


def _schedule_terminal_notifier_remove(terminal_notifier: str, group: str, delay_seconds: float) -> None:
    try:
        delay = max(0.0, float(delay_seconds))
    except Exception:
        delay = 4.0
    python = sys.executable or "python3"
    code = (
        "import subprocess,sys,time\n"
        "tn=sys.argv[1]\n"
        "group=sys.argv[2]\n"
        "delay=float(sys.argv[3])\n"
        "time.sleep(max(0.0, delay))\n"
        "try:\n"
        "  subprocess.run([tn, '-remove', group], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1.0, check=False)\n"
        "except Exception:\n"
        "  pass\n"
    )
    subprocess.Popen(
        [python, "-c", code, terminal_notifier, group, str(delay)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _maybe_auto_remove_notification_if_visible(terminal_notifier: str, group: str | None) -> None:
    if sys.platform != "darwin":
        return
    if not terminal_notifier:
        return
    if not group:
        return

    enabled = os.environ.get("CODEX_NOTIFY_AUTO_REMOVE_IF_VISIBLE", "0").strip()
    if enabled in ("0", "false", "FALSE", "off", "OFF", "no", "NO"):
        return

    if _frontmost_bundle_id() != ITERM2_BUNDLE_ID:
        return

    pane_id = os.environ.get("TMUX_PANE", "").strip()
    if not pane_id:
        return

    tmux_bin = _find_tmux()
    if not tmux_bin:
        return
    socket = _tmux_socket_from_env()
    # Be conservative when multiple tmux clients are attached: "active in any client"
    # is not equivalent to "visible to the user right now".
    if _tmux_client_count(tmux_bin, socket) != 1:
        return
    if not _tmux_pane_is_active_in_any_client(tmux_bin, socket, pane_id):
        return

    try:
        delay_seconds = float(os.environ.get("CODEX_NOTIFY_AUTO_REMOVE_DELAY_SECONDS", "4.0"))
    except ValueError:
        delay_seconds = 4.0
    _schedule_terminal_notifier_remove(terminal_notifier, group, delay_seconds)


def _default_on_click_command(*, cwd: str, title: str) -> str | None:
    # Allow manual override (useful for custom routing).
    override = os.environ.get("CODEX_NOTIFY_ON_CLICK", "").strip()
    if override:
        return override

    if not os.environ.get("TMUX") and not os.environ.get("TMUX_PANE"):
        return None

    tmux_bin = _find_tmux()
    if not tmux_bin:
        return None

    if not os.path.isfile(ON_CLICK_SCRIPT):
        return None

    socket = _tmux_socket_from_env()
    pane_id = os.environ.get("TMUX_PANE", "").strip() or _tmux_display(tmux_bin, socket, "#{pane_id}")
    if not pane_id:
        return None

    session_id = _tmux_display(tmux_bin, socket, "#{session_id}", target=pane_id)
    session_name = _tmux_display(tmux_bin, socket, "#{session_name}", target=pane_id)
    window_id = _tmux_display(tmux_bin, socket, "#{window_id}", target=pane_id)
    window_name = _tmux_display(tmux_bin, socket, "#{window_name}", target=pane_id)
    client_name = _tmux_display(tmux_bin, socket, "#{client_name}")
    client_tty = _tmux_display(tmux_bin, socket, "#{client_tty}")

    argv: list[str] = [sys.executable or "python3", ON_CLICK_SCRIPT, "--tmux-bin", tmux_bin]
    if client_name:
        argv.extend(["--client", client_name])
    if client_tty:
        argv.extend(["--client-tty", client_tty])
    if socket:
        argv.extend(["--tmux-socket", socket])
    if session_id:
        argv.extend(["--session-id", session_id])
    if session_name:
        argv.extend(["--session-name", session_name])
    if window_id:
        argv.extend(["--window-id", window_id])
    if window_name:
        argv.extend(["--window-name", window_name])
    argv.extend(["--pane-id", pane_id])
    if cwd:
        argv.extend(["--cwd", cwd])
    if title:
        argv.extend(["--notification-title", title])

    return _shell_join(argv)


def _notify_macos(title: str, message: str, *, group: str | None = None, cwd: str | None = None) -> None:
    if sys.platform != "darwin":
        return
    if not title:
        title = "Codex"
    if not message:
        message = "Turn complete"

    terminal_notifier = _find_terminal_notifier()
    if terminal_notifier:
        cmd: list[str] = [terminal_notifier, "-title", title, "-message", message, "-activate", ITERM2_BUNDLE_ID]
        if group:
            cmd.extend(["-group", group])

        on_click = _default_on_click_command(cwd=cwd or "", title=title)
        if on_click:
            cmd.extend(["-execute", on_click])

        subprocess.run(
            cmd,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        _maybe_auto_remove_notification_if_visible(terminal_notifier, group)
        return

    applescript = (
        "on run argv\n"
        "  display notification (item 2 of argv) with title (item 1 of argv)\n"
        "end run\n"
    )
    subprocess.run(
        ["osascript", "-e", applescript, title, message],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _git_repo_root(cwd: str) -> str | None:
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None

    root = (result.stdout or "").strip()
    return root if root else None


def _git_branch_name(cwd: str) -> str | None:
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None

    branch = (result.stdout or "").strip()
    if not branch:
        return None

    if branch != "HEAD":
        return branch

    # Detached HEAD: report a short SHA instead.
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--short", "HEAD"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return "detached"

    sha = (result.stdout or "").strip()
    return f"detached@{sha}" if sha else "detached"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return 0

    try:
        payload: Any = json.loads(argv[1])
    except Exception:
        return 0

    if not isinstance(payload, dict):
        return 0

    if payload.get("type") != "agent-turn-complete":
        return 0

    cwd = payload.get("cwd") or ""
    if not isinstance(cwd, str):
        cwd = ""

    thread_id = payload.get("thread-id")
    pane_id = os.environ.get("TMUX_PANE", "").strip()
    pane_key = pane_id[1:] if pane_id.startswith("%") else pane_id
    pane_group = f"codex-pane-{pane_key}" if pane_key else ""
    group = pane_group or (f"codex-{thread_id}" if isinstance(thread_id, str) and thread_id else "codex")
    if not isinstance(thread_id, str):
        thread_id = ""

    turn_id = payload.get("turn-id")
    if not isinstance(turn_id, str):
        turn_id = ""

    repo_root = _git_repo_root(cwd)
    project_path = repo_root or cwd
    project = os.path.basename(project_path.rstrip("/")) if project_path else None

    branch = _git_branch_name(cwd) if repo_root else None
    branch_extra = branch if branch and branch not in ("main", "master") else None

    if project and branch_extra:
        title = f"Codex ({project}@{branch_extra})"
    elif project:
        title = f"Codex ({project})"
    else:
        title = "Codex"

    assistant_message = payload.get("last-assistant-message")
    if isinstance(assistant_message, str):
        assistant_message = _normalize(assistant_message)
    else:
        assistant_message = ""

    message = assistant_message
    if not message:
        inputs = payload.get("input-messages")
        if isinstance(inputs, list):
            message = _normalize(" ".join(str(item) for item in inputs if item))

    message = _truncate(message or "Turn complete", MAX_MESSAGE_CHARS)

    _write_turn_complete_marker(thread_id=thread_id, turn_id=turn_id, cwd=cwd, title=title, message=message)
    tmux_bin = _find_tmux()
    if tmux_bin:
        socket = _tmux_socket_from_env()
        server_pid = _tmux_display(tmux_bin, socket, "#{pid}") or ""
        _gc_turn_complete_markers(current_server_pid=server_pid)
    _notify_macos(title, message, group=group, cwd=cwd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
