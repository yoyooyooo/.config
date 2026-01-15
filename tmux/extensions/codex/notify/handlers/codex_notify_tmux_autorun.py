#!/usr/bin/env python3
import json
import os
import re
import shutil
import subprocess
import sys
import time
from typing import Any


DEFAULT_REMAINING = int(os.environ.get("CODEX_TMUX_AUTORUN_DEFAULT_REMAINING", "3"))
STATE_DIR = os.path.expanduser("~/.codex/tmux_autorun_state")
TMUX_TIMEOUT_SECONDS = float(os.environ.get("CODEX_TMUX_AUTORUN_TMUX_TIMEOUT_SECONDS", "1.0"))
PROMPT_CHECK_RETRIES = int(os.environ.get("CODEX_TMUX_AUTORUN_PROMPT_CHECK_RETRIES", "5"))
PROMPT_CHECK_DELAY_SECONDS = float(os.environ.get("CODEX_TMUX_AUTORUN_PROMPT_CHECK_DELAY_SECONDS", "0.2"))
REQUIRE_PROMPT = os.environ.get("CODEX_TMUX_AUTORUN_REQUIRE_PROMPT", "").strip() == "1"
DRY_RUN = os.environ.get("CODEX_TMUX_AUTORUN_DRY_RUN", "").strip() == "1"


def _slugify(value: str) -> str:
    out: list[str] = []
    for ch in value.strip().lower():
        if ("a" <= ch <= "z") or ("0" <= ch <= "9"):
            out.append(ch)
        else:
            out.append("_")
    slug = "".join(out).strip("_")
    while "__" in slug:
        slug = slug.replace("__", "_")
    return slug or "unknown"


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


def _tmux_argv(tmux_bin: str, socket: str | None, args: list[str]) -> list[str]:
    argv = [tmux_bin]
    if socket:
        argv.extend(["-S", socket])
    argv.extend(args)
    return argv


def _tmux_capture(tmux_bin: str, socket: str | None, args: list[str]) -> str | None:
    try:
        result = subprocess.run(
            _tmux_argv(tmux_bin, socket, args),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=TMUX_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    value = (result.stdout or "").rstrip("\n")
    return value or None


def _tmux_ok(tmux_bin: str, socket: str | None, args: list[str]) -> bool:
    try:
        result = subprocess.run(
            _tmux_argv(tmux_bin, socket, args),
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=TMUX_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _pane_exists(tmux_bin: str, socket: str | None, pane_id: str) -> bool:
    return bool(_tmux_capture(tmux_bin, socket, ["display-message", "-p", "-t", pane_id, "#{pane_id}"]))


def _pane_looks_idle(capture: str) -> bool:
    if not capture:
        return False
    # From Codex TUI source: the status indicator shows "(… • esc to interrupt)"
    # when the interrupt hint is visible (typically while a task is running).
    if "esc to interrupt" in capture:
        return False
    if "again to interrupt" in capture:
        return False
    return "›" in capture


def _extract_tmux_directive(message: str) -> str | None:
    if not message:
        return None
    lines = message.splitlines()
    in_fence = False
    in_fence_flags: list[bool] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            in_fence_flags.append(True)
            continue
        in_fence_flags.append(in_fence)

    min_index = max(0, len(lines) - 30)
    for idx in range(len(lines) - 1, min_index - 1, -1):
        if in_fence_flags[idx]:
            continue
        line = lines[idx].strip()
        if line.startswith("[tmux]") and line != "[tmux]":
            return line
    return None


def _parse_remaining(line: str) -> int | None:
    match = re.search(r"\bremaining\s*=\s*(\d+)\b", line)
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def _state_path(thread_id: str) -> str:
    return os.path.join(STATE_DIR, f"{_slugify(thread_id)}.json")


def _load_state(path: str) -> dict[str, Any] | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _save_state(path: str, state: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp_path = f"{path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp_path, path)


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

    pane_id = os.environ.get("TMUX_PANE", "").strip()
    if not pane_id:
        return 0

    thread_id = payload.get("thread-id")
    if not isinstance(thread_id, str) or not thread_id:
        thread_id = "unknown"

    turn_id = payload.get("turn-id")
    if not isinstance(turn_id, str):
        turn_id = ""

    assistant_message = payload.get("last-assistant-message")
    if not isinstance(assistant_message, str):
        assistant_message = ""

    directive = _extract_tmux_directive(assistant_message)
    if not directive:
        return 0

    tmux_bin = _find_tmux()
    if not tmux_bin:
        return 0

    socket = _tmux_socket_from_env()
    if not _pane_exists(tmux_bin, socket, pane_id):
        return 0

    state_path = _state_path(thread_id)
    state = _load_state(state_path) or {}
    if state.get("last_turn_id") == turn_id:
        return 0

    remaining_override = _parse_remaining(directive)
    remaining_from_state = state.get("remaining")
    if not isinstance(remaining_from_state, int):
        remaining_from_state = None

    reset = re.search(r"\breset\s*=\s*1\b", directive) is not None
    if reset and remaining_override is not None:
        remaining = remaining_override
    elif remaining_from_state is None:
        remaining = remaining_override if remaining_override is not None else DEFAULT_REMAINING
    else:
        remaining = remaining_from_state

    if remaining <= 0:
        _save_state(state_path, {"remaining": 0, "last_turn_id": turn_id})
        return 0

    ready = False
    for _ in range(max(1, PROMPT_CHECK_RETRIES)):
        capture = _tmux_capture(tmux_bin, socket, ["capture-pane", "-pt", pane_id, "-S", "-30"])
        if capture and _pane_looks_idle(capture):
            ready = True
            break
        time.sleep(PROMPT_CHECK_DELAY_SECONDS)

    if not ready and REQUIRE_PROMPT:
        return 0

    if DRY_RUN:
        _save_state(state_path, {"remaining": remaining - 1, "last_turn_id": turn_id})
        return 0

    ok = _tmux_ok(tmux_bin, socket, ["send-keys", "-t", pane_id, "-l", directive, "Enter"])
    if not ok:
        return 0

    _save_state(state_path, {"remaining": remaining - 1, "last_turn_id": turn_id})
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
