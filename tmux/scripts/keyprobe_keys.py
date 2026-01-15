#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import select
import sys
import termios
import time
import tty
from datetime import datetime
from typing import Any


def _read_sequence(fd: int, first_timeout_s: float = 4.0, chunk_timeout_s: float = 0.05, max_bytes: int = 128):
    ready, _, _ = select.select([fd], [], [], first_timeout_s)
    if not ready:
        return None

    data = bytearray(os.read(fd, 1))
    while len(data) < max_bytes:
        ready, _, _ = select.select([fd], [], [], chunk_timeout_s)
        if not ready:
            break
        chunk = os.read(fd, max_bytes - len(data))
        if not chunk:
            break
        data.extend(chunk)

    return bytes(data)


def _format_bytes(data):
    if data is None:
        return {"len": 0, "hex": None, "repr": None}

    return {
        "len": len(data),
        "hex": data.hex(" "),
        "repr": data.decode("utf-8", errors="backslashreplace"),
    }


def _default_out_path(mode: str) -> str:
    env = os.environ.get("TMUX_KEYPROBE_OUT")
    if env:
        return os.path.expanduser(env)

    if mode == "test":
        return os.path.expanduser("~/.config/tmux/run/keyprobe_output.json")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return os.path.expanduser(f"~/.config/tmux/run/keyprobe_record_{stamp}.json")


def _write_json(out_path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def _run_test_mode(out_path: str, per_key_timeout_s: float) -> None:
    tests = [
        ("i", "按 i（不带 Option）"),
        ("k", "按 k（不带 Option）"),
        ("j", "按 j（不带 Option）"),
        ("l", "按 l（不带 Option）"),
        ("Opt--", "按 Option+-"),
        ("Opt-=", "按 Option+="),
        ("S-Opt--", "按 Shift+Option+-"),
        ("S-Opt-=", "按 Shift+Option+="),
        ("S-Opt-[", "按 Shift+Option+["),
        ("S-Opt-]", "按 Shift+Option+]"),
        ("S-Opt-I", "按 Shift+Option+I"),
        ("S-Opt-K", "按 Shift+Option+K"),
        ("S-Opt-J", "按 Shift+Option+J"),
        ("S-Opt-L", "按 Shift+Option+L"),
        ("Opt-I", "按 Option+I"),
        ("Opt-K", "按 Option+K"),
        ("Opt-J", "按 Option+J"),
        ("Opt-L", "按 Option+L"),
        ("Opt-[", "按 Option+["),
        ("Opt-]", "按 Option+]"),
    ]

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        results = {
            "timestamp": datetime.now().isoformat(timespec="seconds"),
            "mode": "test",
            "per_key_timeout_s": per_key_timeout_s,
            "tests": {},
        }

        sys.stdout.write(f"tmux 按键探针（test）：逐项按键；{per_key_timeout_s:g} 秒无输入会跳过。\n")
        sys.stdout.write("如果某项一直 NO INPUT，可能是：tmux 已绑定并拦截（这通常是好事）/ 被系统全局快捷键拦截 / iTerm2 未发送可识别序列 / 输入法死键。\n\n")
        sys.stdout.flush()

        for key, label in tests:
            sys.stdout.write(f"{label} ... ")
            sys.stdout.flush()

            data = _read_sequence(fd, first_timeout_s=per_key_timeout_s)
            results["tests"][key] = _format_bytes(data)

            if data is None:
                sys.stdout.write("NO INPUT\n")
            else:
                info = results["tests"][key]
                sys.stdout.write(f"len={info['len']} hex={info['hex']} repr={info['repr']}\n")
            sys.stdout.flush()

        _write_json(out_path, results)

        sys.stdout.write(f"\n已写入：{out_path}\n")
        sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def _run_record_mode(
    out_path: str,
    duration_s: float | None,
    idle_stop_s: float | None,
    max_events: int | None,
    chunk_timeout_s: float,
    max_bytes: int,
    echo: bool,
) -> None:
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        start = time.monotonic()
        last_input = start
        events: list[dict[str, Any]] = []
        stop_reason: str | None = None

        sys.stdout.write("tmux 按键探针（record）：开始录制；按 Ctrl-C 结束。\n")
        sys.stdout.write("注意：请不要在此模式输入密码/私密内容。\n")
        sys.stdout.write(f"输出：{out_path}\n\n")
        sys.stdout.flush()

        while True:
            now = time.monotonic()

            if duration_s is not None and now - start >= duration_s:
                stop_reason = "duration"
                break

            if max_events is not None and len(events) >= max_events:
                stop_reason = "max_events"
                break

            timeout_s = 0.5
            if duration_s is not None:
                timeout_s = min(timeout_s, max(0.0, duration_s - (now - start)))
            if idle_stop_s is not None:
                timeout_s = min(timeout_s, max(0.0, idle_stop_s - (now - last_input)))

            data = _read_sequence(fd, first_timeout_s=timeout_s, chunk_timeout_s=chunk_timeout_s, max_bytes=max_bytes)
            if data is None:
                if idle_stop_s is not None and time.monotonic() - last_input >= idle_stop_s:
                    stop_reason = "idle"
                    break
                continue

            at = time.monotonic()
            last_input = at

            event = {"t_s": round(at - start, 4), **_format_bytes(data)}
            events.append(event)

            if echo:
                sys.stdout.write(
                    f"{len(events):03d} t={event['t_s']} len={event['len']} hex={event['hex']} repr={event['repr']}\n"
                )
                sys.stdout.flush()

            if data in (b"\x03", b"\x04"):
                stop_reason = "ctrl_c_or_d"
                break

        payload = {
            "timestamp": datetime.now().isoformat(timespec="seconds"),
            "mode": "record",
            "config": {
                "duration_s": duration_s,
                "idle_stop_s": idle_stop_s,
                "max_events": max_events,
                "chunk_timeout_s": chunk_timeout_s,
                "max_bytes": max_bytes,
                "echo": echo,
                "stop_bytes": ["03", "04"],
            },
            "stop_reason": stop_reason,
            "events": events,
        }
        _write_json(out_path, payload)
        sys.stdout.write(f"\n已写入：{out_path}\n")
        sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="keyprobe_keys.py",
        description="tmux 按键探针：test=逐项测试；record=通用录制（输出 JSON）。",
    )
    sub = parser.add_subparsers(dest="cmd", required=False)

    test = sub.add_parser("test", help="逐项测试模式（默认）")
    test.add_argument("--out", default=None, help="输出路径（默认：TMUX_KEYPROBE_OUT 或 ~/.config/tmux/run/keyprobe_output.json）")
    test.add_argument("--timeout", type=float, default=6.0, help="每项等待输入的超时时间（秒）")

    record = sub.add_parser("record", help="通用录制模式（按 Ctrl-C 结束）")
    record.add_argument("--out", default=None, help="输出路径（默认：TMUX_KEYPROBE_OUT 或 ~/.config/tmux/run/keyprobe_record_*.json）")
    record.add_argument("--duration", type=float, default=None, help="最多录制多少秒（默认不限）")
    record.add_argument(
        "--idle-stop",
        type=float,
        nargs="?",
        const=3.0,
        default=None,
        help="多久无输入自动结束（秒）；不带值时默认 3 秒；不传则不限",
    )
    record.add_argument("--max-events", type=int, default=None, help="最多记录多少条事件（默认不限）")
    record.add_argument("--chunk-timeout", type=float, default=0.05, help="同一按键序列的聚合窗口（秒）")
    record.add_argument("--max-bytes", type=int, default=128, help="单条事件最多读取多少字节")
    record.add_argument("--echo", action="store_true", help="把每条事件实时打印到 stdout")

    args = parser.parse_args(argv)
    if args.cmd is None:
        args.cmd = "test"
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(list(sys.argv[1:] if argv is None else argv))

    out_path = os.path.expanduser(args.out) if args.out else _default_out_path(args.cmd)

    if args.cmd == "test":
        _run_test_mode(out_path=out_path, per_key_timeout_s=float(args.timeout))
        return 0

    if args.cmd == "record":
        _run_record_mode(
            out_path=out_path,
            duration_s=args.duration,
            idle_stop_s=args.idle_stop,
            max_events=args.max_events,
            chunk_timeout_s=float(args.chunk_timeout),
            max_bytes=int(args.max_bytes),
            echo=bool(args.echo),
        )
        return 0

    raise RuntimeError(f"unknown cmd: {args.cmd}")


if __name__ == "__main__":
    raise SystemExit(main())
