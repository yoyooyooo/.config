import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELOAD_SCRIPT = ROOT / "scripts" / "panel" / "codex_reload_active.sh"
FORK_SCRIPT = ROOT / "scripts" / "panel" / "codex_fork_active.sh"
EXPORT_SCRIPT = ROOT / "scripts" / "panel" / "codex_export_last_message_to_obsidian.sh"


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
        if [[ "$1" == "display-message" && "$2" == "-p" && "$5" == "#{pane_current_path}" ]]; then
          printf '%s\\n' "/tmp/project with spaces"
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


if __name__ == "__main__":
    unittest.main()
