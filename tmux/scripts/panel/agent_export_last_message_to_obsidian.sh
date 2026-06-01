#!/usr/bin/env bash
# desc: 导出当前 Codex / Pi / OMP / Claude Code 最后一条回复到 Obsidian 临时预览 tab
# usage: 在 M-p 面板选择；写入 CODEX_OBSIDIAN_PREVIEW_DIR/Codex Last Message.md，并在 Obsidian 打开
# note: Codex 优先读 rollout JSONL；Pi/OMP 读 ~/.pi|~/.omp/agent/sessions；Claude Code 优先读 ~/.claude/projects/<cwd>/<sessionId>.jsonl；要求 M-p 绑定传入 ORIGIN_PANE_ID
set -euo pipefail

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

die() {
  printf '%s\n' "$1"
  pause
  exit 0
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

obsidian_bin_kind() {
  local bin="$1"
  case "$bin" in
    */Obsidian.app/Contents/MacOS/obsidian)
      printf 'app\n'
      ;;
    *)
      printf 'cli\n'
      ;;
  esac
}

resolve_obsidian_bin() {
  local configured="${CODEX_OBSIDIAN_CLI_BIN:-}"
  if [[ -n "${configured:-}" ]]; then
    if [[ -x "$configured" ]]; then
      printf '%s\t%s\n' "$(obsidian_bin_kind "$configured")" "$configured"
      return 0
    fi
    return 1
  fi

  if command -v obsidian >/dev/null 2>&1; then
    local found
    found="$(command -v obsidian)"
    printf '%s\t%s\n' "$(obsidian_bin_kind "$found")" "$found"
    return 0
  fi

  local macos_app_bin="/Applications/Obsidian.app/Contents/MacOS/obsidian"
  if [[ -x "$macos_app_bin" ]]; then
    printf 'app\t%s\n' "$macos_app_bin"
    return 0
  fi

  return 1
}

target_pane="${ORIGIN_PANE_ID:-}"
if [[ -z "${target_pane:-}" ]]; then
  die "缺少 ORIGIN_PANE_ID：请使用 M-p 打开 panel（它会设置 @panel_origin_pane_id）。"
fi
if [[ "$target_pane" == *"#{pane_id}"* || "$target_pane" == *"#{pane_"* || "$target_pane" == *"pane_id"* && "$target_pane" != %* ]]; then
  die "ORIGIN_PANE_ID 看起来没有被 tmux 展开成真实 pane（期望形如 %85），当前值：${target_pane}"
fi

if ! require_cmd python3; then
  die "找不到 python3。"
fi
if ! require_cmd osascript; then
  die "找不到 osascript，无法把 Obsidian 窗口置于前台。"
fi
obsidian_resolved="$(resolve_obsidian_bin || true)"
obsidian_kind="${obsidian_resolved%%$'\t'*}"
obsidian_bin="${obsidian_resolved#*$'\t'}"
if [[ -z "${obsidian_bin:-}" ]]; then
  die "找不到 obsidian CLI。可设置 CODEX_OBSIDIAN_CLI_BIN=/Applications/Obsidian.app/Contents/MacOS/obsidian"
fi

session_json=""
session_probe="$HOME/.config/tmux/scripts/codex_session_id.py"
if [[ -f "$session_probe" ]]; then
  session_json="$(python3 "$session_probe" --pane "$target_pane" --json 2>/dev/null || true)"
fi

vault_name="${CODEX_OBSIDIAN_VAULT_NAME:-personal}"
vault_dir="${CODEX_OBSIDIAN_VAULT_DIR:-/Users/yoyo/Documents/note/obsidian/personal}"
preview_dir="${CODEX_OBSIDIAN_PREVIEW_DIR:-$vault_dir/inbox/codex-preview}"
preview_file_name="${CODEX_OBSIDIAN_PREVIEW_FILE:-Codex Last Message.md}"

export TARGET_PANE="$target_pane"
export SESSION_JSON="$session_json"
export CODEX_OBSIDIAN_VAULT_DIR="$vault_dir"
export CODEX_OBSIDIAN_PREVIEW_DIR="$preview_dir"
export CODEX_OBSIDIAN_PREVIEW_FILE="$preview_file_name"

write_json="$(
  python3 <<'PY'
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)


def try_run(cmd: list[str]) -> str | None:
    try:
        return run(cmd)
    except Exception:
        return None


def tmux_value(pane: str, fmt: str) -> str | None:
    out = try_run(["tmux", "display-message", "-p", "-t", pane, fmt])
    if out is None:
        return None
    value = out.strip()
    return value if value else None


def same_path(left: str | Path, right: str | Path) -> bool:
    left_path = Path(left).expanduser()
    right_path = Path(right).expanduser()
    try:
        return left_path.resolve() == right_path.resolve()
    except Exception:
        return os.path.normpath(str(left_path)) == os.path.normpath(str(right_path))


def path_is_relative_to(path: Path, base: Path) -> bool:
    try:
        path.expanduser().resolve().relative_to(base.expanduser().resolve())
        return True
    except Exception:
        return False


def is_descendant(pid: int, ancestor_pid: int, parent_by_pid: dict[int, int], *, max_hops: int = 200) -> bool:
    cur = pid
    for _ in range(max_hops):
        if cur == ancestor_pid:
            return True
        cur = parent_by_pid.get(cur, 0)
        if cur <= 1:
            return False
    return False


def iter_ps_table() -> tuple[dict[int, int], dict[int, str]]:
    out = run(["ps", "-axo", "pid=,ppid=,command="])
    parent_by_pid: dict[int, int] = {}
    command_by_pid: dict[int, str] = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        parent_by_pid[pid] = ppid
        command_by_pid[pid] = parts[2]
    return parent_by_pid, command_by_pid


def extract_codex_text(rollout_path: Path) -> str:
    last_text: str | None = None
    try:
        lines = rollout_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        fail(f"找不到 rollout 文件：{rollout_path}")

    for line in lines:
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = event.get("payload")
        if not isinstance(payload, dict):
            continue
        if payload.get("role") != "assistant":
            continue
        content = payload.get("content")
        if not isinstance(content, list):
            continue
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") != "output_text":
                continue
            text = item.get("text")
            if isinstance(text, str):
                parts.append(text)
        if parts:
            last_text = "\n".join(parts)

    if last_text is None:
        fail(f"未在 rollout 文件中找到 assistant output_text：{rollout_path}")
    return last_text.rstrip() + "\n"


def project_slug(cwd: str) -> str:
    return cwd.replace("/", "-")


def message_text(content: object) -> str:
    if isinstance(content, str):
        return content.strip("\n")
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
            continue
        if not isinstance(item, dict):
            continue
        # Claude Code 会把 reasoning 放在 thinking / redacted_thinking 中；导出只取公开 text。
        if item.get("type") != "text":
            continue
        text = item.get("text")
        if isinstance(text, str):
            parts.append(text)
    return "\n".join(parts).strip("\n")


AGENT_COMMAND_RE = {
    "omp": re.compile(r"@oh-my-pi/pi-coding-agent|(^|[\s/])omp(\s|$)"),
    "pi": re.compile(r"@earendil-works/pi-coding-agent|(^|[\s/])pi(\s|$)"),
}


def agent_base(kind: str) -> Path:
    if kind == "omp":
        return Path.home() / ".omp" / "agent"
    if kind == "pi":
        return Path.home() / ".pi" / "agent"
    fail(f"未知 agent 类型：{kind}")


def session_path_matches_agent(path: Path, kind: str) -> bool:
    sessions_dir = agent_base(kind) / "sessions"
    return path.suffix == ".jsonl" and path_is_relative_to(path, sessions_dir)


def read_session_cwd(path: Path) -> str | None:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for _ in range(20):
                line = handle.readline()
                if not line:
                    return None
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                cwd = event.get("cwd")
                if isinstance(cwd, str) and cwd:
                    return cwd
    except FileNotFoundError:
        return None
    return None


def read_pi_omp_text(session_path: Path) -> str | None:
    last_text: str | None = None
    try:
        lines = session_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return None

    for line in lines:
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") != "message":
            continue
        message = event.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        text = message_text(message.get("content"))
        if text.strip():
            last_text = text

    if last_text is None:
        return None
    return last_text.rstrip() + "\n"


def extract_pi_omp_text(session_path: Path, kind: str) -> str:
    text = read_pi_omp_text(session_path)
    if text is None:
        if not session_path.exists():
            fail(f"找不到 {kind} session 文件：{session_path}")
        fail(f"未在 {kind} session 文件中找到 assistant text：{session_path}")
    return text


def detect_pi_omp_agent(pane: str) -> dict[str, object] | None:
    pane_pid_raw = tmux_value(pane, "#{pane_pid}")
    if not pane_pid_raw:
        return None
    try:
        pane_pid = int(pane_pid_raw)
    except ValueError:
        return None

    parent_by_pid, command_by_pid = iter_ps_table()
    descendants = [
        (pid, command)
        for pid, command in command_by_pid.items()
        if is_descendant(pid, pane_pid, parent_by_pid)
    ]

    for kind in ("omp", "pi"):
        matcher = AGENT_COMMAND_RE[kind]
        for pid, command in sorted(descendants):
            if matcher.search(command):
                return {
                    "kind": kind,
                    "pid": pid,
                    "command": command,
                    "cwd": tmux_value(pane, "#{pane_current_path}"),
                    "tty": tmux_value(pane, "#{pane_tty}"),
                }
    return None


def lsof_session_candidates(pid: int, kind: str) -> list[Path]:
    out = try_run(["lsof", "-p", str(pid), "-Fn"])
    if not out:
        return []
    candidates: list[Path] = []
    for line in out.splitlines():
        if not line.startswith("n"):
            continue
        path = Path(line[1:]).expanduser()
        if path.is_file() and session_path_matches_agent(path, kind):
            candidates.append(path)
    return candidates


def breadcrumb_session_candidates(kind: str, pane: str, cwd: str | None, tty: str | None) -> list[Path]:
    terminal_dir = agent_base(kind) / "terminal-sessions"
    names: list[str] = []
    if pane:
        names.append(f"tmux-{pane}")
    if tty:
        names.append(Path(tty).name)

    candidates: list[Path] = []
    seen: set[str] = set()
    for name in names:
        if not name or name in seen:
            continue
        seen.add(name)
        breadcrumb = terminal_dir / name
        try:
            lines = breadcrumb.read_text(encoding="utf-8", errors="replace").splitlines()
        except FileNotFoundError:
            continue
        if len(lines) < 2:
            continue
        recorded_cwd = lines[0].strip()
        if cwd and recorded_cwd and not same_path(recorded_cwd, cwd):
            continue
        path = Path(lines[1].strip()).expanduser()
        if path.is_file() and session_path_matches_agent(path, kind):
            candidates.append(path)
    return candidates


def encoded_cwd_names(cwd: str) -> list[str]:
    names: list[str] = []
    cwd_path = Path(cwd).expanduser()
    home_path = Path.home().expanduser()

    try:
        rel = cwd_path.resolve().relative_to(home_path.resolve())
        rel_name = str(rel).replace(os.sep, "-")
        names.append(f"-{rel_name}" if rel_name else "-")
    except Exception:
        pass

    stripped = os.path.normpath(str(cwd_path)).strip(os.sep)
    names.append(f"--{stripped.replace(os.sep, '-')}--")
    names.append(str(cwd_path).replace(os.sep, "-"))

    dedup: list[str] = []
    seen: set[str] = set()
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        dedup.append(name)
    return dedup


def cwd_session_candidates(kind: str, cwd: str | None) -> list[Path]:
    if not cwd:
        return []
    sessions_dir = agent_base(kind) / "sessions"
    candidates: list[Path] = []
    for name in encoded_cwd_names(cwd):
        session_dir = sessions_dir / name
        if not session_dir.is_dir():
            continue
        for path in session_dir.glob("*.jsonl"):
            if read_session_cwd(path) == cwd or same_path(read_session_cwd(path) or "", cwd):
                candidates.append(path)
    return sorted(candidates, key=lambda p: p.stat().st_mtime, reverse=True)


def pi_omp_session_candidates(agent: dict[str, object], pane: str) -> list[tuple[str, Path]]:
    kind = str(agent["kind"])
    pid = int(agent["pid"])
    cwd = agent.get("cwd") if isinstance(agent.get("cwd"), str) else None
    tty = agent.get("tty") if isinstance(agent.get("tty"), str) else None

    candidates: list[tuple[str, Path]] = []
    for path in lsof_session_candidates(pid, kind):
        candidates.append(("lsof", path))
    for path in breadcrumb_session_candidates(kind, pane, cwd, tty):
        candidates.append(("breadcrumb", path))
    for path in cwd_session_candidates(kind, cwd):
        candidates.append(("cwd", path))
    return candidates


def extract_pi_omp_agent_text(pane: str) -> str | None:
    agent = detect_pi_omp_agent(pane)
    if not agent:
        return None
    candidates = pi_omp_session_candidates(agent, pane)
    if not candidates:
        fail(f"检测到 {agent['kind']}，但未找到当前 pane 对应 session JSONL。")

    kind = str(agent["kind"])
    no_text: list[Path] = []
    cwd_paths: list[Path] = []
    for source, path in candidates:
        if source == "cwd":
            cwd_paths.append(path)
            continue
        text = read_pi_omp_text(path)
        if text:
            return text
        no_text.append(path)
        if source in {"lsof", "breadcrumb"}:
            fail(f"检测到 {kind} session，但未找到 assistant text：{path}")

    visible = best_visible_session(cwd_paths, pane)
    if visible:
        return visible[1]

    text_candidates = [(path, read_pi_omp_text(path)) for path in cwd_paths]
    text_candidates = [(path, text) for path, text in text_candidates if text]
    if len(text_candidates) == 1:
        return text_candidates[0][1]
    if len(text_candidates) > 1:
        fail(f"检测到 {kind}，但当前 pane 无精确 session 锚点，且 cwd 下有多个候选 session；已拒绝猜测。")

    detail = f"：{no_text[0]}" if no_text else ""
    fail(f"检测到 {kind}，但候选 session 未找到 assistant text{detail}")


def extract_claude_project_text(transcript_path: Path) -> str | None:
    last_text: str | None = None
    try:
        lines = transcript_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return None

    for line in lines:
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") != "assistant":
            continue
        message = event.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        text = message_text(message.get("content"))
        if text.strip():
            last_text = text

    if last_text is None:
        return None
    return last_text.rstrip() + "\n"


def claude_transcript_candidates(session_id: str, cwd: str | None) -> list[Path]:
    projects_dir = Path.home() / ".claude" / "projects"
    candidates: list[Path] = []
    if projects_dir.is_dir():
        candidates.extend(projects_dir.glob(f"*/{session_id}.jsonl"))
        if cwd:
            candidates.append(projects_dir / project_slug(cwd) / f"{session_id}.jsonl")

    dedup: list[Path] = []
    seen: set[Path] = set()
    for path in candidates:
        try:
            resolved = path.expanduser().resolve()
        except FileNotFoundError:
            resolved = path.expanduser()
        if resolved in seen:
            continue
        seen.add(resolved)
        if path.exists():
            dedup.append(path)
    return sorted(dedup, key=lambda p: p.stat().st_mtime, reverse=True)


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
CLAUDE_BLOCK_RE = re.compile(r"^\s*[⏺●]\s+")
CLAUDE_TOOL_RE = re.compile(
    r"^\s*[⏺●]\s*(Bash|Read|Edit|Write|MultiEdit|Grep|Glob|LS|Todo|Task|WebFetch|WebSearch|Notebook|ExitPlanMode)\b"
)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def compact_for_match(text: str) -> str:
    return re.sub(r"\s+", "", strip_ansi(text))


def pane_capture_text(pane: str) -> str:
    out = try_run(["tmux", "capture-pane", "-p", "-t", pane, "-S", "-1200"])
    return strip_ansi(out or "")


def visible_text_score(text: str, capture: str) -> int:
    capture_compact = compact_for_match(capture)
    text_compact = compact_for_match(text)
    if len(text_compact) < 12 or not capture_compact:
        return 0

    score = 0
    seen: set[str] = set()
    for line in text.splitlines():
        snippet = compact_for_match(line)
        if len(snippet) < 12:
            continue
        snippet = snippet[:120]
        if snippet in seen:
            continue
        seen.add(snippet)
        if snippet in capture_compact:
            score += min(len(snippet), 120)

    if score > 0:
        return score

    for start in range(0, max(len(text_compact) - 40, 0), 80):
        snippet = text_compact[start : start + 80]
        if len(snippet) >= 40 and snippet in capture_compact:
            return len(snippet)
    return 0


def best_visible_session(candidates: list[Path], pane: str) -> tuple[Path, str] | None:
    capture = pane_capture_text(pane)
    best: tuple[int, Path, str] | None = None
    for path in candidates:
        text = read_pi_omp_text(path)
        if not text:
            continue
        score = visible_text_score(text, capture)
        if score <= 0:
            continue
        if best is None or score > best[0]:
            best = (score, path, text)
    if best is None:
        return None
    return best[1], best[2]


def clean_claude_capture_block(lines: list[str]) -> str:
    if not lines:
        return ""
    cleaned = lines[:]
    cleaned[0] = re.sub(r"^\s*[⏺●]\s*", "", cleaned[0])
    while cleaned and not cleaned[-1].strip():
        cleaned.pop()
    body = cleaned[1:]
    indents = [len(line) - len(line.lstrip(" ")) for line in body if line.strip()]
    if indents:
        trim = min(min(indents), 2)
        if trim > 0:
            body = [line[trim:] if line.startswith(" " * trim) else line for line in body]
    return "\n".join([cleaned[0], *body]).strip("\n")


def extract_claude_capture_text(pane: str) -> str | None:
    out = try_run(["tmux", "capture-pane", "-p", "-t", pane, "-S", "-400"])
    if not out:
        return None
    lines = [strip_ansi(line).rstrip() for line in out.splitlines()]
    blocks: list[list[str]] = []
    current: list[str] = []

    for line in lines:
        if CLAUDE_BLOCK_RE.match(line):
            if current:
                blocks.append(current)
            current = [line]
            continue
        if not current:
            continue
        stripped = line.strip()
        if (
            stripped.startswith("❯")
            or stripped.startswith("✻ ")
            or stripped.startswith("※ recap:")
            or stripped.startswith("────────────────")
            or re.match(r"^(Mac|Linux|WSL)\s+", stripped)
        ):
            blocks.append(current)
            current = []
            continue
        current.append(line)
    if current:
        blocks.append(current)

    for block in reversed(blocks):
        head = block[0]
        if CLAUDE_TOOL_RE.match(head):
            continue
        text = clean_claude_capture_block(block)
        if text.strip():
            return text.rstrip() + "\n"
    return None


def extract_claude_text(pane: str) -> str:
    pane_pid_raw = try_run(["tmux", "display-message", "-p", "-t", pane, "#{pane_pid}"])
    if not pane_pid_raw:
        fail(f"无法读取 pane pid：{pane}")
    try:
        pane_pid = int(pane_pid_raw.strip())
    except ValueError:
        fail(f"pane pid 不是数字：{pane_pid_raw.strip()}")

    parent_by_pid, command_by_pid = iter_ps_table()
    claude_re = re.compile(r"(^|[\s/])claude(\s|$)")
    errors: list[str] = []

    for pid, command in sorted(command_by_pid.items()):
        if not claude_re.search(command):
            continue
        if not is_descendant(pid, pane_pid, parent_by_pid):
            continue

        session_path = Path.home() / ".claude" / "sessions" / f"{pid}.json"
        try:
            session = json.loads(session_path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"{session_path}: {exc}")
            continue
        session_id = session.get("sessionId")
        cwd = session.get("cwd")
        if not isinstance(session_id, str) or not session_id:
            errors.append(f"{session_path}: 缺少 sessionId")
            continue

        for transcript in claude_transcript_candidates(session_id, cwd if isinstance(cwd, str) else None):
            text = extract_claude_project_text(transcript)
            if text:
                return text
            errors.append(f"{transcript}: 未找到 assistant text")

    capture_text = extract_claude_capture_text(pane)
    if capture_text:
        return capture_text

    details = f"；{'; '.join(errors[-3:])}" if errors else ""
    fail(f"pane {pane} 未检测到可导出的 Codex / Pi / OMP / Claude Code 最后一条回复{details}")


def extract_agent_text() -> str:
    session_raw = os.environ.get("SESSION_JSON", "").strip()
    if session_raw:
        session = json.loads(session_raw)
        rollout_raw = session.get("rollout_path")
        if isinstance(rollout_raw, str) and rollout_raw:
            return extract_codex_text(Path(rollout_raw).expanduser())

    pane = os.environ.get("TARGET_PANE", "").strip()
    if not pane:
        fail("缺少 TARGET_PANE。")
    pi_omp_text = extract_pi_omp_agent_text(pane)
    if pi_omp_text:
        return pi_omp_text
    return extract_claude_text(pane)

vault_dir = Path(os.environ["CODEX_OBSIDIAN_VAULT_DIR"]).expanduser().resolve()
preview_dir = Path(os.environ["CODEX_OBSIDIAN_PREVIEW_DIR"]).expanduser()
if not preview_dir.is_absolute():
    preview_dir = vault_dir / preview_dir
preview_dir = preview_dir.resolve()
preview_file = preview_dir / os.environ["CODEX_OBSIDIAN_PREVIEW_FILE"]

try:
    relative_path = preview_file.resolve().relative_to(vault_dir)
except ValueError:
    fail(f"预览文件必须位于 Obsidian vault 内：{preview_file}")

text = extract_agent_text()
preview_dir.mkdir(parents=True, exist_ok=True)
preview_file.write_text(text, encoding="utf-8")

print(
    json.dumps(
        {
            "file": str(preview_file),
            "obsidian_path": relative_path.as_posix(),
            "chars": len(text),
        },
        ensure_ascii=False,
    )
)
PY
)" || die "导出失败。"

obsidian_path="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["obsidian_path"])' <<<"$write_json")"

if [[ "$obsidian_kind" == "app" ]]; then
  if require_cmd open; then
    encoded_path="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$obsidian_path")"
    encoded_vault="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$vault_name")"
    open "obsidian://open?vault=${encoded_vault}&file=${encoded_path}" >/dev/null 2>&1 || die "Obsidian 打开失败：$obsidian_path"
  else
    nohup "$obsidian_bin" open "path=$obsidian_path" newtab "vault=$vault_name" >/dev/null 2>&1 </dev/null &
    disown "$!" 2>/dev/null || true
  fi
else
  "$obsidian_bin" open "path=$obsidian_path" newtab "vault=$vault_name" >/dev/null 2>&1 || die "Obsidian 打开失败：$obsidian_path"
fi
osascript -e 'tell application "Obsidian" to activate' >/dev/null 2>&1 || true
exit 0
