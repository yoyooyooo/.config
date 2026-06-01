#!/usr/bin/env bash
set -euo pipefail

client_tty="${1:-}"
socket_path="${2:-}"
runner="${HOME}/.config/tmux/scripts/codex_tmux_progress_tmux.sh"
log_file="${HOME}/.config/tmux/run/codex-progress-panel.log"
metadata_file="$(mktemp "${TMPDIR:-/tmp}/codex-progress-panel-meta.XXXXXX")"
rows_file="$(mktemp "${TMPDIR:-/tmp}/codex-progress-panel-rows.XXXXXX")"
trap 'rm -f "$metadata_file" "$rows_file"' EXIT

log_panel() {
  [[ "${CODEX_TMUX_PROGRESS_PANEL_DEBUG:-0}" == "1" ]] || return 0
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0
  {
    printf '%s tty=%s socket=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$client_tty" "$socket_path" "$*"
  } >>"$log_file" 2>/dev/null || return 0
  if tail -n 120 "$log_file" >"${log_file}.$$" 2>/dev/null; then
    mv "${log_file}.$$" "$log_file" 2>/dev/null || true
  else
    rm -f "${log_file}.$$" 2>/dev/null || true
  fi
}

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

if [[ ! -x "$runner" ]]; then
  log_panel "missing-runner path=$runner"
  printf '%s\n' "codex tmux progress runner 不存在：$runner"
  pause
  exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
  log_panel "missing-fzf"
  printf '%s\n' "fzf 未安装：Codex Sessions 面板依赖 fzf。"
  pause
  exit 0
fi

log_panel "start"
rows="$("$runner" --event tmux-list --socket "$socket_path" --limit "${CODEX_TMUX_PROGRESS_PANEL_LIMIT:-10}" </dev/null 2>/dev/null || true)"
if [[ -z "${rows:-}" ]]; then
  log_panel "empty-rows"
  printf '%s\n' "没有 running / unread / recent Codex pane。"
  pause
  exit 0
fi
printf '%s\n' "$rows" >"$rows_file"
log_panel "rows=$(printf '%s\n' "$rows" | wc -l | tr -d ' ') first=$(printf '%s\n' "$rows" | head -n 1)"

tmux_args=()
if [[ -n "$socket_path" ]]; then
  tmux_args=(-S "$socket_path")
fi
tmux "${tmux_args[@]}" list-panes -a -F '#{pane_id}	#{session_name}	#{window_name}	#{pane_title}' >"$metadata_file" 2>/dev/null || true

items="$(
  python3 - "$metadata_file" "$rows_file" <<'PY'
import sys
import unicodedata

meta_path = sys.argv[1]
rows_path = sys.argv[2]
metadata = {}
try:
    with open(meta_path, "r", encoding="utf-8") as handle:
        for line in handle:
            pane_id, session_name, window_name, pane_title = (line.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
            if pane_id:
                metadata[pane_id] = (session_name, window_name, pane_title)
except OSError:
    pass

labels = {
    "running": "● running",
    "unread": "● unread",
    "recent": "· recent",
}

def width(text: str) -> int:
    total = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        total += 2 if unicodedata.east_asian_width(char) in {"F", "W"} else 1
    return total

def fit(text: str, target: int) -> str:
    text = text or ""
    result = []
    used = 0
    for char in text:
        char_width = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in {"F", "W"} else 1)
        if used + char_width > target:
            break
        result.append(char)
        used += char_width
    return "".join(result) + (" " * max(0, target - used))

with open(rows_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        fields = raw.rstrip("\n").split("\t")
        if len(fields) < 8:
            continue
        group, state, pane_id, window_id, session_id, _label, cwd, timestamp = fields[:8]
        session_name = fields[8] if len(fields) > 8 else ""
        window_name = fields[9] if len(fields) > 9 else ""
        pane_title = fields[10] if len(fields) > 10 else ""
        meta_session, meta_window, meta_title = metadata.get(pane_id, ("", "", ""))
        session_name = session_name or meta_session or f"(session {session_id})"
        window_name = window_name or meta_window or f"(window {window_id})"
        pane_title = pane_title or meta_title or f"(pane {pane_id})"
        cwd_name = (cwd.rstrip("/").rsplit("/", 1)[-1] if cwd else "") or "-"
        display = " ".join(
            [
                fit(labels.get(group, group), 10),
                fit(session_name, 18),
                fit(window_name, 24),
                fit(pane_title, 26),
                fit(cwd_name, 22),
            ]
        )
        print("\t".join([display, session_name, window_name, pane_title, cwd_name, timestamp, group, cwd, state, pane_id, window_id, session_id, labels.get(group, group)]))
PY
)"
log_panel "items=$(printf '%s\n' "$items" | wc -l | tr -d ' ') first=$(printf '%s\n' "$items" | head -n 1)"

selected="$(
  printf '%s\n' "$items" | FZF_DEFAULT_OPTS= fzf \
    --reverse \
    --exit-0 \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='codex> ' \
    --header=$'Enter=跳转 | 列: status session window pane cwd' \
    --preview 'tmux capture-pane -ep -t {10} -S - 2>/dev/null' \
    --preview-window='down,65%,wrap,follow' \
    --color='fg:#d8dee9,bg:#2e3440,hl:#ebcb8b,fg+:#eceff4,bg+:#3d434a,hl+:#ebcb8b,info:#88c0d0,prompt:#a3be8c,pointer:#ebcb8b,marker:#ebcb8b,spinner:#88c0d0,header:#81a1c1'
)" || true

if [[ -z "${selected:-}" ]]; then
  log_panel "no-selection"
  exit 0
fi

log_panel "selected=$selected"
pane_id="$(printf '%s' "$selected" | awk -F '\t' '{print $10}')"
if [[ -n "$pane_id" ]]; then
  log_panel "jump pane=$pane_id"
  "$runner" --event tmux-jump --socket "$socket_path" --client-tty "$client_tty" --pane-id "$pane_id" >/dev/null 2>&1 || true
fi
