#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys


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


def _notify_via_osascript(title: str, message: str) -> None:
    applescript = (
        "on run argv\n"
        "  display notification (item 2 of argv) with title (item 1 of argv)\n"
        "end run\n"
    )
    subprocess.run(
        ["/usr/bin/osascript", "-e", applescript, title, message],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="macOS notify helper (terminal-notifier preferred)")
    parser.add_argument("--title", default="Notify")
    parser.add_argument("--message", default="")
    parser.add_argument("--subtitle")
    parser.add_argument("--group")
    parser.add_argument("--remove-group", dest="remove_group", help="Remove a notification by group id (terminal-notifier)")
    parser.add_argument("--activate", help="Bundle id, e.g. com.googlecode.iterm2")
    parser.add_argument("--execute", help="On click command string, e.g. sh -lc '...'")
    parser.add_argument("--ignore-dnd", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv[1:])

    terminal_notifier = _find_terminal_notifier()

    if args.remove_group:
        group = (args.remove_group or "").strip()
        if not group:
            return 0
        if not terminal_notifier:
            return 0

        cmd: list[str] = [terminal_notifier, "-remove", group]
        if args.dry_run:
            print(" ".join(shlex_quote(x) for x in cmd))
            return 0
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0

    title = (args.title or "").strip() or "Notify"
    message = (args.message or "").strip() or "Done"

    if not terminal_notifier:
        _notify_via_osascript(title, message)
        return 0

    cmd: list[str] = [terminal_notifier, "-title", title, "-message", message]
    if args.subtitle:
        cmd.extend(["-subtitle", args.subtitle])
    if args.group:
        cmd.extend(["-group", args.group])
    if args.activate:
        cmd.extend(["-activate", args.activate])
    if args.execute:
        cmd.extend(["-execute", args.execute])
    if args.ignore_dnd:
        cmd.append("-ignoreDnD")

    if args.dry_run:
        print(" ".join(shlex_quote(x) for x in cmd))
        return 0

    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


def shlex_quote(value: str) -> str:
    import shlex

    return shlex.quote(value)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

