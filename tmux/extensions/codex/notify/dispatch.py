#!/usr/bin/env python3
import glob
import json
import os
import subprocess
import sys
from typing import Any


SUBHANDLER_TIMEOUT_SECONDS = float(os.environ.get("CODEX_NOTIFY_SUBHANDLER_TIMEOUT_SECONDS", "2.0"))
ENABLE_TMUX_AUTORUN = os.environ.get("CODEX_NOTIFY_ENABLE_TMUX_AUTORUN", "").strip() == "1"


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


def _read_payload_json(argv: list[str]) -> str:
    if len(argv) == 2:
        return argv[1]
    try:
        value = sys.stdin.read()
    except Exception:
        value = ""
    return (value or "").strip()


def _run(handler: str, payload_json: str) -> None:
    handler = os.path.expanduser(handler)
    if not os.path.isfile(handler):
        return

    try:
        if os.path.samefile(handler, __file__):
            return
    except Exception:
        pass

    if handler.endswith(".py"):
        python = sys.executable or "python3"
        argv = [python, handler, payload_json]
    else:
        if not os.access(handler, os.X_OK):
            return
        argv = [handler, payload_json]

    try:
        subprocess.run(
            argv,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=SUBHANDLER_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return


def _split_paths(raw: str) -> list[str]:
    raw = (raw or "").strip()
    if not raw:
        return []
    # Prefer OS-native separator; also accept "," as a convenience.
    parts = [part for part in raw.replace(",", os.pathsep).split(os.pathsep) if part.strip()]
    return [os.path.expanduser(part.strip()) for part in parts]


def _discover_extra_handlers(handler_dir: str, slug: str) -> list[str]:
    handler_dir = os.path.expanduser(handler_dir)
    if not os.path.isdir(handler_dir):
        return []

    patterns = [
        f"codex_notify_{slug}.py",
        f"codex_notify_{slug}.sh",
        f"codex_notify_{slug}__*.py",
        f"codex_notify_{slug}__*.sh",
    ]
    out: list[str] = []
    for pattern in patterns:
        out.extend(glob.glob(os.path.join(handler_dir, pattern)))
    return sorted(set(out))


def main(argv: list[str]) -> int:
    payload_json = _read_payload_json(argv)
    if not payload_json:
        return 0

    try:
        payload: Any = json.loads(payload_json)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0

    event_type = payload.get("type")
    if not isinstance(event_type, str) or not event_type:
        return 0
    slug = _slugify(event_type)

    dispatch_dir = os.path.dirname(__file__)
    builtin_dir = os.path.join(dispatch_dir, "handlers")

    seen: set[str] = set()

    def run_once(handler: str) -> None:
        handler = os.path.abspath(os.path.expanduser(handler))
        if handler in seen:
            return
        seen.add(handler)
        _run(handler, payload_json)

    # Built-in handlers (ours)
    run_once(os.path.join(builtin_dir, "codex_notify_handler.py"))
    if ENABLE_TMUX_AUTORUN:
        run_once(os.path.join(builtin_dir, "codex_notify_tmux_autorun.py"))

    # User handlers (fan-out)
    # - CODEX_NOTIFY_USER_HANDLER: single script path (called with 1 arg: payload_json)
    # - CODEX_NOTIFY_EXTRA_HANDLER_DIRS: additional directories containing event handlers
    user_handler = os.environ.get("CODEX_NOTIFY_USER_HANDLER", "").strip()
    extra_dirs = _split_paths(os.environ.get("CODEX_NOTIFY_EXTRA_HANDLER_DIRS", ""))

    for handler_dir in extra_dirs:
        for handler in _discover_extra_handlers(handler_dir, slug):
            run_once(handler)

    if user_handler:
        run_once(user_handler)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

