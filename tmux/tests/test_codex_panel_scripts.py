import os
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELOAD_SCRIPT = ROOT / "scripts" / "panel" / "codex_reload_active.sh"
FORK_SCRIPT = ROOT / "scripts" / "panel" / "codex_fork_active.sh"
EXPORT_SCRIPT = ROOT / "scripts" / "panel" / "agent_export_last_message_to_obsidian.sh"


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def make_fake_home(
    tmp: Path,
    *,
    pane_pid: int = 100,
    matched_pids: list[int] | None = None,
    rollout_path: Path | None = None,
) -> Path:
    if matched_pids is None:
        matched_pids = []
    home = tmp / "home"
    scripts = home / ".config" / "tmux" / "scripts"
    write_executable(
        scripts / "codex_session_id.py",
        f"""
        #!/usr/bin/env python3
        import json
        print(json.dumps({{
            "session_id": "019dd4f7-8dc0-7111-aabf-3b7a3697600f",
            "rollout_path": {str(rollout_path or "")!r},
            "pane_pid": {pane_pid},
            "matched_pids": {matched_pids!r}
        }}))
        """,
    )
    return home


def write_fake_tmux(path: Path) -> None:
    write_executable(
        path,
        """
        #!/usr/bin/env bash
        if [[ "$1" == "display-message" && "$2" == "-p" && "$5" == "#{pane_pid}" ]]; then
          printf '%s\\n' "${FAKE_TMUX_PANE_PID:-100}"
          exit 0
        fi
        if [[ "$1" == "display-message" && "$2" == "-p" && "$5" == "#{pane_current_path}" ]]; then
          printf '%s\\n' "${FAKE_TMUX_PANE_CWD:-/tmp/project with spaces}"
          exit 0
        fi
        if [[ "$1" == "display-message" && "$2" == "-p" && "$5" == "#{pane_tty}" ]]; then
          printf '%s\\n' "${FAKE_TMUX_PANE_TTY:-/dev/ttys060}"
          exit 0
        fi
        if [[ "$1" == "capture-pane" ]]; then
          printf '%s\\n' "${FAKE_TMUX_CAPTURE:-}"
          exit 0
        fi
        printf '%s\\n' "$*" >> "$TMUX_CALL_LOG"
        """,
    )


class CodexPanelScriptsTest(unittest.TestCase):
    def test_reload_respawns_when_fork_wrapper_is_pane_process(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            home = make_fake_home(tmp, pane_pid=185, matched_pids=[185, 186, 187])
            fake_bin = tmp / "bin"
            tmux_log = tmp / "tmux.log"
            write_fake_tmux(fake_bin / "tmux")

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "TMUX_CALL_LOG": str(tmux_log),
                }
            )

            subprocess.run(["bash", str(RELOAD_SCRIPT)], env=env, check=True, timeout=5)

            calls = tmux_log.read_text(encoding="utf-8").splitlines()
            self.assertTrue(
                any(
                    line.startswith("respawn-pane -k -c /tmp/project with spaces -t %185 ")
                    and "'codex' resume '019dd4f7-8dc0-7111-aabf-3b7a3697600f'" in line
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(any("send-keys -t %185 -l" in line for line in calls), calls)

    def test_reload_sends_resume_for_nested_codex_process(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            home = make_fake_home(tmp, pane_pid=185, matched_pids=[])
            fake_bin = tmp / "bin"
            tmux_log = tmp / "tmux.log"
            write_fake_tmux(fake_bin / "tmux")

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "TMUX_CALL_LOG": str(tmux_log),
                }
            )

            subprocess.run(["bash", str(RELOAD_SCRIPT)], env=env, check=True, timeout=5)

            calls = tmux_log.read_text(encoding="utf-8").splitlines()
            self.assertTrue(
                any(
                    line == "send-keys -t %185 -l codex resume 019dd4f7-8dc0-7111-aabf-3b7a3697600f"
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(any(line.startswith("respawn-pane ") for line in calls), calls)

    def test_fork_wrapper_keeps_pane_alive_after_codex_exits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            home = make_fake_home(tmp)
            fake_bin = tmp / "bin"
            tmux_log = tmp / "tmux.log"
            split_cmd_log = tmp / "split-cmd.log"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                home / ".config" / "tmux" / "scripts" / "smart_split_133.sh",
                """
                #!/usr/bin/env bash
                printf '%s' "$TMUX_SMART_SPLIT_CMD" > "$SMART_SPLIT_CMD_LOG"
                printf '{"pane_id":"%%999"}\\n'
                """,
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "TMUX_CALL_LOG": str(tmux_log),
                    "SMART_SPLIT_CMD_LOG": str(split_cmd_log),
                }
            )

            subprocess.run(["bash", str(FORK_SCRIPT)], env=env, check=True, timeout=5)

            split_cmd = split_cmd_log.read_text(encoding="utf-8")
            self.assertIn("code -ne 130", split_cmd)
            self.assertIn("code -ne 143", split_cmd)
            self.assertIn("read -r -n 1", split_cmd)
            self.assertIn('exec "${SHELL:-/bin/zsh}" -l', split_cmd)

    def test_export_last_assistant_message_to_obsidian_tab(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            rollout = tmp / "rollout.jsonl"
            rollout.write_text(
                "\n".join(
                    [
                        '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"older"}]}}',
                        '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ignore"}]}}',
                        '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"# Last\\n\\nBody"}]}}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            home = make_fake_home(tmp, rollout_path=rollout)
            fake_bin = tmp / "bin"
            obsidian_log = tmp / "obsidian.log"
            osascript_log = tmp / "osascript.log"
            preview_dir = tmp / "vault" / "tmp" / "codex preview"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                fake_bin / "obsidian",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OBSIDIAN_CALL_LOG"
                """,
            )
            write_executable(
                fake_bin / "osascript",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OSASCRIPT_CALL_LOG"
                """,
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "TMUX_CALL_LOG": str(tmp / "tmux.log"),
                    "CODEX_OBSIDIAN_VAULT_NAME": "personal",
                    "CODEX_OBSIDIAN_VAULT_DIR": str(tmp / "vault"),
                    "CODEX_OBSIDIAN_PREVIEW_DIR": str(preview_dir),
                    "OBSIDIAN_CALL_LOG": str(obsidian_log),
                    "OSASCRIPT_CALL_LOG": str(osascript_log),
                }
            )

            result = subprocess.run(
                ["bash", str(EXPORT_SCRIPT)],
                env=env,
                input="\n",
                text=True,
                check=True,
                timeout=5,
                capture_output=True,
            )

            preview_file = preview_dir / "Codex Last Message.md"
            self.assertEqual(preview_file.read_text(encoding="utf-8"), "# Last\n\nBody\n")
            self.assertNotIn("按任意键关闭", result.stdout)
            obsidian_calls = obsidian_log.read_text(encoding="utf-8").splitlines()
            self.assertIn('open path=tmp/codex preview/Codex Last Message.md newtab vault=personal', obsidian_calls)
            self.assertFalse(any("workspace:open-in-new-window" in call for call in obsidian_calls), obsidian_calls)
            self.assertIn('-e tell application "Obsidian" to activate', osascript_log.read_text(encoding="utf-8").splitlines())

    def test_export_uses_configured_obsidian_cli_when_path_cannot_find_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            rollout = tmp / "rollout.jsonl"
            rollout.write_text(
                '{"payload":{"role":"assistant","content":[{"type":"output_text","text":"Body"}]}}\n',
                encoding="utf-8",
            )
            home = make_fake_home(tmp, rollout_path=rollout)
            fake_bin = tmp / "bin"
            obsidian_log = tmp / "obsidian.log"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                fake_bin / "obsidian-app-cli",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OBSIDIAN_CALL_LOG"
                """,
            )
            write_executable(
                fake_bin / "osascript",
                """
                #!/usr/bin/env bash
                :
                """,
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "TMUX_CALL_LOG": str(tmp / "tmux.log"),
                    "CODEX_OBSIDIAN_CLI_BIN": str(fake_bin / "obsidian-app-cli"),
                    "CODEX_OBSIDIAN_VAULT_DIR": str(tmp / "vault"),
                    "CODEX_OBSIDIAN_PREVIEW_DIR": str(tmp / "vault" / "tmp"),
                    "OBSIDIAN_CALL_LOG": str(obsidian_log),
                }
            )

            subprocess.run(["bash", str(EXPORT_SCRIPT)], env=env, input="\n", text=True, check=True, timeout=5)

            obsidian_calls = obsidian_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("open path=tmp/Codex Last Message.md newtab vault=personal", obsidian_calls)

    def test_export_backgrounds_macos_app_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            rollout = tmp / "rollout.jsonl"
            rollout.write_text(
                '{"payload":{"role":"assistant","content":[{"type":"output_text","text":"Body"}]}}\n',
                encoding="utf-8",
            )
            home = make_fake_home(tmp, rollout_path=rollout)
            fake_bin = tmp / "bin"
            fake_app = tmp / "Applications" / "Obsidian.app" / "Contents" / "MacOS"
            open_log = tmp / "open.log"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                fake_app / "obsidian",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OBSIDIAN_CALL_LOG"
                sleep 30
                """,
            )
            write_executable(
                fake_bin / "open",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OPEN_CALL_LOG"
                """,
            )
            write_executable(
                fake_bin / "osascript",
                """
                #!/usr/bin/env bash
                :
                """,
            )

            script = tmp / "export.sh"
            original = EXPORT_SCRIPT.read_text(encoding="utf-8")
            script.write_text(
                original.replace("/Applications/Obsidian.app/Contents/MacOS/obsidian", str(fake_app / "obsidian")),
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                    "ORIGIN_PANE_ID": "%185",
                    "TMUX_CALL_LOG": str(tmp / "tmux.log"),
                    "CODEX_OBSIDIAN_VAULT_DIR": str(tmp / "vault"),
                    "CODEX_OBSIDIAN_PREVIEW_DIR": str(tmp / "vault" / "tmp"),
                    "OBSIDIAN_CALL_LOG": str(tmp / "obsidian.log"),
                    "OPEN_CALL_LOG": str(open_log),
                }
            )

            subprocess.run(["bash", str(script)], env=env, input="\n", text=True, check=True, timeout=5)

            for _ in range(20):
                if open_log.exists():
                    break
                time.sleep(0.05)
            open_calls = open_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("obsidian://open?vault=personal&file=tmp%2FCodex%20Last%20Message.md", open_calls)

    def test_export_claude_code_last_assistant_message_to_obsidian_tab(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            home = tmp / "home"
            project_cwd = "/tmp/project"
            project_slug = "-tmp-project"
            session_id = "ee92809d-7a5c-4205-bf58-dc779b2ed2cb"
            session_dir = home / ".claude" / "sessions"
            session_dir.mkdir(parents=True)
            (session_dir / "200.json").write_text(
                (
                    '{"pid":200,'
                    f'"sessionId":"{session_id}",'
                    f'"cwd":"{project_cwd}",'
                    '"kind":"interactive","entrypoint":"cli"}'
                ),
                encoding="utf-8",
            )
            transcript_dir = home / ".claude" / "projects" / project_slug
            transcript_dir.mkdir(parents=True)
            (transcript_dir / f"{session_id}.jsonl").write_text(
                "\n".join(
                    [
                        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"older"},{"type":"thinking","thinking":"hidden"}]}}',
                        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret only"}]}}',
                        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"# Claude Last\\n\\nBody"},{"type":"redacted_thinking","data":"hidden"}]}}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            fake_bin = tmp / "bin"
            obsidian_log = tmp / "obsidian.log"
            osascript_log = tmp / "osascript.log"
            preview_dir = tmp / "vault" / "tmp" / "claude preview"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                fake_bin / "ps",
                """
                #!/usr/bin/env bash
                cat <<'OUT'
                  100     1 zsh
                  200   100 claude --dangerously-skip-permissions
                OUT
                """,
            )
            write_executable(
                fake_bin / "obsidian",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OBSIDIAN_CALL_LOG"
                """,
            )
            write_executable(
                fake_bin / "osascript",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OSASCRIPT_CALL_LOG"
                """,
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "FAKE_TMUX_PANE_PID": "100",
                    "TMUX_CALL_LOG": str(tmp / "tmux.log"),
                    "CODEX_OBSIDIAN_VAULT_NAME": "personal",
                    "CODEX_OBSIDIAN_VAULT_DIR": str(tmp / "vault"),
                    "CODEX_OBSIDIAN_PREVIEW_DIR": str(preview_dir),
                    "OBSIDIAN_CALL_LOG": str(obsidian_log),
                    "OSASCRIPT_CALL_LOG": str(osascript_log),
                }
            )

            result = subprocess.run(
                ["bash", str(EXPORT_SCRIPT)],
                env=env,
                input="\n",
                text=True,
                check=True,
                timeout=5,
                capture_output=True,
            )

            preview_file = preview_dir / "Codex Last Message.md"
            self.assertEqual(preview_file.read_text(encoding="utf-8"), "# Claude Last\n\nBody\n")
            self.assertNotIn("secret", preview_file.read_text(encoding="utf-8"))
            self.assertNotIn("按任意键关闭", result.stdout)
            obsidian_calls = obsidian_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("open path=tmp/claude preview/Codex Last Message.md newtab vault=personal", obsidian_calls)

    def test_export_omp_last_assistant_message_from_lsof_session(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            home = tmp / "home"
            session_path = home / ".omp" / "agent" / "sessions" / "-tmp-project with spaces" / "omp.jsonl"
            session_path.parent.mkdir(parents=True)
            session_path.write_text(
                "\n".join(
                    [
                        '{"type":"session","cwd":"/tmp/project with spaces"}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"older"}]}}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"}]}}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"# OMP Last\\n\\nBody"},{"type":"thinking","thinking":"hidden"}]}}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            fake_bin = tmp / "bin"
            obsidian_log = tmp / "obsidian.log"
            preview_dir = tmp / "vault" / "tmp" / "omp preview"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                fake_bin / "ps",
                """
                #!/usr/bin/env bash
                cat <<'OUT'
                  100     1 zsh
                  200   100 bun /Users/yoyo/.bun/bin/omp
                OUT
                """,
            )
            write_executable(
                fake_bin / "lsof",
                f"""
                #!/usr/bin/env bash
                if [[ "$1" == "-p" && "$2" == "200" && "$3" == "-Fn" ]]; then
                  printf '%s\\n' p200
                  printf '%s\\n' n{session_path}
                  exit 0
                fi
                exit 1
                """,
            )
            write_executable(
                fake_bin / "obsidian",
                """
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$OBSIDIAN_CALL_LOG"
                """,
            )
            write_executable(
                fake_bin / "osascript",
                """
                #!/usr/bin/env bash
                :
                """,
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "FAKE_TMUX_PANE_PID": "100",
                    "TMUX_CALL_LOG": str(tmp / "tmux.log"),
                    "CODEX_OBSIDIAN_VAULT_DIR": str(tmp / "vault"),
                    "CODEX_OBSIDIAN_PREVIEW_DIR": str(preview_dir),
                    "OBSIDIAN_CALL_LOG": str(obsidian_log),
                }
            )

            subprocess.run(["bash", str(EXPORT_SCRIPT)], env=env, input="\n", text=True, check=True, timeout=5)

            preview_file = preview_dir / "Codex Last Message.md"
            self.assertEqual(preview_file.read_text(encoding="utf-8"), "# OMP Last\n\nBody\n")

    def test_export_omp_last_assistant_message_from_tty_breadcrumb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            home = tmp / "home"
            session_path = home / ".omp" / "agent" / "sessions" / "-tmp-project with spaces" / "omp.jsonl"
            session_path.parent.mkdir(parents=True)
            session_path.write_text(
                "\n".join(
                    [
                        '{"type":"session","cwd":"/tmp/project with spaces"}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"# OMP Breadcrumb\\n\\nBody"}]}}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            breadcrumb = home / ".omp" / "agent" / "terminal-sessions" / "ttys060"
            breadcrumb.parent.mkdir(parents=True)
            breadcrumb.write_text(f"/tmp/project with spaces\n{session_path}\n", encoding="utf-8")

            fake_bin = tmp / "bin"
            preview_dir = tmp / "vault" / "tmp" / "omp breadcrumb"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                fake_bin / "ps",
                """
                #!/usr/bin/env bash
                cat <<'OUT'
                  100     1 zsh
                  200   100 /opt/homebrew/bin/bun /Users/yoyo/.bun/bin/omp
                OUT
                """,
            )
            write_executable(
                fake_bin / "lsof",
                """
                #!/usr/bin/env bash
                exit 1
                """,
            )
            write_executable(
                fake_bin / "obsidian",
                """
                #!/usr/bin/env bash
                :
                """,
            )
            write_executable(
                fake_bin / "osascript",
                """
                #!/usr/bin/env bash
                :
                """,
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "FAKE_TMUX_PANE_PID": "100",
                    "TMUX_CALL_LOG": str(tmp / "tmux.log"),
                    "CODEX_OBSIDIAN_VAULT_DIR": str(tmp / "vault"),
                    "CODEX_OBSIDIAN_PREVIEW_DIR": str(preview_dir),
                }
            )

            subprocess.run(["bash", str(EXPORT_SCRIPT)], env=env, input="\n", text=True, check=True, timeout=5)

            preview_file = preview_dir / "Codex Last Message.md"
            self.assertEqual(preview_file.read_text(encoding="utf-8"), "# OMP Breadcrumb\n\nBody\n")

    def test_export_pi_last_assistant_message_from_cwd_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw)
            home = tmp / "home"
            session_dir = home / ".pi" / "agent" / "sessions" / "--tmp-project with spaces--"
            session_path = session_dir / "pi.jsonl"
            session_path.parent.mkdir(parents=True)
            session_path.write_text(
                "\n".join(
                    [
                        '{"type":"session","cwd":"/tmp/project with spaces"}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"older"}]}}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"}]}}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"# Pi Visible Last\\n\\nA distinctive body line from the visible pane."}]}}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            newer_ok = session_dir / "newer-ok.jsonl"
            newer_ok.write_text(
                "\n".join(
                    [
                        '{"type":"session","cwd":"/tmp/project with spaces"}',
                        '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OK"}]}}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            now = time.time()
            os.utime(session_path, (now, now))
            os.utime(newer_ok, (now + 10, now + 10))

            fake_bin = tmp / "bin"
            preview_dir = tmp / "vault" / "tmp" / "pi preview"
            write_fake_tmux(fake_bin / "tmux")
            write_executable(
                fake_bin / "ps",
                """
                #!/usr/bin/env bash
                cat <<'OUT'
                  100     1 zsh
                  200   100 pi -c --no-extensions
                  201   200 pi
                OUT
                """,
            )
            write_executable(
                fake_bin / "lsof",
                """
                #!/usr/bin/env bash
                exit 1
                """,
            )
            write_executable(
                fake_bin / "obsidian",
                """
                #!/usr/bin/env bash
                :
                """,
            )
            write_executable(
                fake_bin / "osascript",
                """
                #!/usr/bin/env bash
                :
                """,
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ORIGIN_PANE_ID": "%185",
                    "FAKE_TMUX_PANE_PID": "100",
                    "FAKE_TMUX_CAPTURE": "# Pi Visible Last\n\nA distinctive body line from the visible pane.",
                    "TMUX_CALL_LOG": str(tmp / "tmux.log"),
                    "CODEX_OBSIDIAN_VAULT_DIR": str(tmp / "vault"),
                    "CODEX_OBSIDIAN_PREVIEW_DIR": str(preview_dir),
                }
            )

            subprocess.run(["bash", str(EXPORT_SCRIPT)], env=env, input="\n", text=True, check=True, timeout=5)

            preview_file = preview_dir / "Codex Last Message.md"
            self.assertEqual(
                preview_file.read_text(encoding="utf-8"),
                "# Pi Visible Last\n\nA distinctive body line from the visible pane.\n",
            )


if __name__ == "__main__":
    unittest.main()
