#!/usr/bin/env python3
import os
import subprocess
import sys


SUBHANDLER_TIMEOUT_SECONDS = float(os.environ.get("CODEX_NOTIFY_SUBHANDLER_TIMEOUT_SECONDS", "2.0"))


def _run(handler: str, payload_json: str) -> None:
    if not os.path.isfile(handler):
        return
    python = sys.executable or "python3"
    try:
        subprocess.run(
            [python, handler, payload_json],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=SUBHANDLER_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return 0

    payload_json = argv[1]
    script_dir = os.path.dirname(__file__)

    _run(os.path.join(script_dir, "codex_notify_handler.py"), payload_json)
    _run(os.path.join(script_dir, "codex_notify_tmux_autorun.py"), payload_json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
