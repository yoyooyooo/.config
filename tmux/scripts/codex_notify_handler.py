#!/usr/bin/env python3
import os
import subprocess
import sys


SUBHANDLER_TIMEOUT_SECONDS = float(os.environ.get("CODEX_NOTIFY_SUBHANDLER_TIMEOUT_SECONDS", "2.0"))
DISPATCHER = os.path.expanduser(
    os.environ.get("CODEX_NOTIFY_DISPATCHER", "~/.config/tmux/extensions/codex/notify/dispatch.py")
)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return 0

    if not os.path.isfile(DISPATCHER):
        return 0

    payload_json = argv[1]
    python = sys.executable or "python3"
    try:
        subprocess.run(
            [python, DISPATCHER, payload_json],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=SUBHANDLER_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

