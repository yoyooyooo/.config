#!/usr/bin/env python3
import importlib.util
import io
from pathlib import Path
import sys
from contextlib import redirect_stdout
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "activity_rank.py"


def load_module():
    spec = importlib.util.spec_from_file_location("activity_rank", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ActivityRankTests(unittest.TestCase):
    def test_windows_prioritize_done_then_activity_time_and_demote_dev_server_noise(self):
        activity_rank = load_module()
        windows = [
            activity_rank.WindowRow("$1", "work", "@1", 1, "vite", 400, True, False, False),
            activity_rank.WindowRow("$1", "work", "@2", 2, "agent", 300, True, False, False),
            activity_rank.WindowRow("$1", "work", "@3", 3, "tests", 350, True, False, False),
            activity_rank.WindowRow("$1", "work", "@4", 4, "done", 100, False, True, False),
            activity_rank.WindowRow("$1", "work", "@5", 5, "idle", 50, False, False, False),
        ]
        panes = [
            activity_rank.PaneRow("@1", "%1", 0, "node", "vite dev server", "/repo", 101),
            activity_rank.PaneRow("@2", "%2", 0, "zsh", "codex agent", "/repo", 102),
            activity_rank.PaneRow("@3", "%3", 0, "pytest", "tests", "/repo", 103),
            activity_rank.PaneRow("@4", "%4", 0, "zsh", "codex agent", "/repo", 104),
            activity_rank.PaneRow("@5", "%5", 0, "zsh", "shell", "/repo", 105),
        ]

        ranked = activity_rank.rank_windows(windows, panes, process_text={})

        self.assertEqual([row.window_id for row in ranked], ["@4", "@3", "@2", "@5", "@1"])
        self.assertEqual(ranked[0].mark, "✓")
        self.assertEqual(ranked[1].mark, "•")
        self.assertEqual(ranked[2].mark, "●")
        self.assertEqual(ranked[-1].mark, "·")

    def test_activity_time_beats_stale_activity_flag_for_non_noise_windows(self):
        activity_rank = load_module()
        windows = [
            activity_rank.WindowRow("$1", "work", "@1", 1, "old-flag", 100, True, False, False),
            activity_rank.WindowRow("$1", "work", "@2", 2, "recent", 500, False, False, False),
        ]
        panes = [
            activity_rank.PaneRow("@1", "%1", 0, "zsh", "shell", "/repo", 101),
            activity_rank.PaneRow("@2", "%2", 0, "pytest", "tests", "/repo", 102),
        ]

        ranked = activity_rank.rank_windows(windows, panes, process_text={})

        self.assertEqual([row.window_id for row in ranked], ["@2", "@1"])

    def test_sessions_aggregate_best_child_without_letting_noise_dominate(self):
        activity_rank = load_module()
        sessions = [
            activity_rank.SessionRow("$1", "1-dev", 500),
            activity_rank.SessionRow("$2", "2-agent", 200),
            activity_rank.SessionRow("$3", "3-done", 100),
        ]
        windows = [
            activity_rank.WindowRow("$1", "1-dev", "@1", 0, "vite", 500, True, False, False),
            activity_rank.WindowRow("$2", "2-agent", "@2", 0, "agent", 200, True, False, False),
            activity_rank.WindowRow("$3", "3-done", "@3", 0, "done", 100, False, True, False),
        ]
        panes = [
            activity_rank.PaneRow("@1", "%1", 0, "node", "vite dev server", "/repo", 101),
            activity_rank.PaneRow("@2", "%2", 0, "zsh", "opencode agent", "/repo", 102),
            activity_rank.PaneRow("@3", "%3", 0, "zsh", "codex agent", "/repo", 103),
        ]

        ranked = activity_rank.rank_sessions(sessions, windows, panes, process_text={})

        self.assertEqual([row.session_id for row in ranked], ["$3", "$2", "$1"])
        self.assertEqual(ranked[0].mark, "✓")
        self.assertEqual(ranked[1].mark, "●")
        self.assertEqual(ranked[2].mark, "·")

    def test_panes_follow_parent_window_rank_and_do_not_force_origin_first(self):
        activity_rank = load_module()
        panes = [
            activity_rank.PaneDetail("$1", "work", "@1", 1, "old", "%1", 0, "node", "vite dev", "/repo", 500, True, False, False, False, 101),
            activity_rank.PaneDetail("$1", "work", "@2", 2, "agent", "%2", 0, "zsh", "codex agent", "/repo", 200, True, False, False, False, 102),
        ]

        ranked = activity_rank.rank_panes(panes, process_text={}, origin_pane_id="%1")

        self.assertEqual([row.pane_id for row in ranked], ["%2", "%1"])
        self.assertEqual(ranked[0].mark, "●")
        self.assertEqual(ranked[1].mark, "·")

    def test_agent_process_tree_activity_is_not_downgraded_by_dev_server_child(self):
        activity_rank = load_module()
        windows = [
            activity_rank.WindowRow("$1", "work", "@1", 1, "agent", 100, True, False, False),
            activity_rank.WindowRow("$1", "work", "@2", 2, "vite", 200, True, False, False),
        ]
        panes = [
            activity_rank.PaneRow("@1", "%1", 0, "zsh", "shell", "/repo", 101),
            activity_rank.PaneRow("@2", "%2", 0, "node", "vite dev server", "/repo", 102),
        ]
        process_text = {
            "%1": "zsh codex node node_modules/vite/bin/vite.js --host",
            "%2": "node node_modules/vite/bin/vite.js --host",
        }

        ranked = activity_rank.rank_windows(windows, panes, process_text=process_text)

        self.assertEqual([row.window_id for row in ranked], ["@1", "@2"])
        self.assertEqual(ranked[0].kind, "agent")
        self.assertEqual(ranked[1].kind, "noise")

    def test_print_panes_does_not_mutate_mru_state(self):
        activity_rank = load_module()
        pane = activity_rank.PaneDetail(
            "$1", "work", "@1", 1, "agent", "%1", 0, "zsh", "codex agent",
            "/repo", 100, True, False, False, False, 101,
        )
        calls = []
        activity_rank.collect_pane_details = lambda: [pane]
        activity_rank.process_text_for_panes = lambda panes: {}
        activity_rank._tmux_set = lambda args: calls.append(args)

        with redirect_stdout(io.StringIO()):
            activity_rank.print_panes()

        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
