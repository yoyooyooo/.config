#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys


TMUX_TIMEOUT_SECONDS = 0.2
HUD_TIMEOUT_SECONDS = 1.0


def _tmux_show_global(option: str) -> str | None:
    tmux = shutil.which("tmux") or "/opt/homebrew/bin/tmux" or "/usr/local/bin/tmux"
    if not tmux or not os.path.isfile(tmux) or not os.access(tmux, os.X_OK):
        return None
    try:
        result = subprocess.run(
            [tmux, "show", "-gqv", option],
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


def _is_disabled(value: str | None) -> bool:
    if not value:
        return False
    lowered = value.strip().lower()
    return lowered in ("0", "false", "off", "no")


def _osascript_hud(*, trigger: str, title_var: str, body_var: str, title: str, body: str) -> bool:
    applescript = (
        "on run argv\n"
        "  set triggerName to item 1 of argv\n"
        "  set titleVarName to item 2 of argv\n"
        "  set bodyVarName to item 3 of argv\n"
        "  set titleMsg to item 4 of argv\n"
        "  set bodyMsg to item 5 of argv\n"
        "  tell application \"BetterTouchTool\"\n"
        "    set_string_variable titleVarName to titleMsg\n"
        "    set_string_variable bodyVarName to bodyMsg\n"
        "    trigger_named_async_without_response triggerName\n"
        "  end tell\n"
        "end run\n"
    )
    try:
        subprocess.run(
            ["/usr/bin/osascript", "-e", applescript, trigger, title_var, body_var, title, body],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=HUD_TIMEOUT_SECONDS,
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


def _fallback_notification(title: str, body: str) -> None:
    applescript = (
        "on run argv\n"
        "  display notification (item 2 of argv) with title (item 1 of argv)\n"
        "end run\n"
    )
    subprocess.run(
        ["/usr/bin/osascript", "-e", applescript, title, body],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="BetterTouchTool HUD notify (toaster)")
    parser.add_argument("--title", default="")
    parser.add_argument("--message", default="")
    parser.add_argument("--trigger")
    parser.add_argument("--title-var")
    parser.add_argument("--body-var")
    parser.add_argument("--no-fallback", action="store_true")
    args = parser.parse_args(argv[1:])

    title = (args.title or "").strip() or "HUD"
    body = (args.message or "").strip()

    trigger = (args.trigger or "").strip() or _tmux_show_global("@tmux_cross_session_btt_hud_trigger") or "btt-hud-overlay"
    title_var = (args.title_var or "").strip() or _tmux_show_global("@tmux_cross_session_btt_hud_title_var") or "hud_title"
    body_var = (args.body_var or "").strip() or _tmux_show_global("@tmux_cross_session_btt_hud_body_var") or "hud_body"

    if _is_disabled(trigger):
        if not args.no_fallback:
            _fallback_notification(title, body or "HUD disabled")
        return 1

    ok = _osascript_hud(trigger=trigger, title_var=title_var, body_var=body_var, title=title, body=body)
    if ok:
        return 0

    if not args.no_fallback:
        _fallback_notification(title, body or "HUD failed")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

