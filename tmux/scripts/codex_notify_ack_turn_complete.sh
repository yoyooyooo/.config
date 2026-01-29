#!/usr/bin/env bash
set -euo pipefail

pane_id="${1:-}"
[[ -n "${pane_id}" ]] || exit 0

turn_complete_dir="${CODEX_TMUX_TURN_COMPLETE_DIR:-$HOME/.config/tmux/run/codex-turn-complete}"

safe_key() {
  local value="$1"
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value//../__}"
  printf '%s' "$value"
}

marker_path="${turn_complete_dir}/$(safe_key "${pane_id}")"

window_id="$(tmux display-message -p -t "${pane_id}" '#{window_id}' 2>/dev/null || true)"
[[ -n "${window_id:-}" ]] || exit 0

marker_exists=0
[[ -f "${marker_path}" ]] && marker_exists=1

if [[ "${marker_exists}" != "1" ]]; then
  current_done="$(tmux show -w -t "${window_id}" -qv @codex_done 2>/dev/null || true)"
  if [[ "${current_done:-}" != "1" ]]; then
    exit 0
  fi
fi

pane_group="codex-pane-$(safe_key "${pane_id#%}")"

thread_id=""
if [[ "${marker_exists}" == "1" ]] && command -v python3 >/dev/null 2>&1; then
  thread_id="$(
    python3 - "${marker_path}" 2>/dev/null <<'PY' || true
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    thread_id = data.get("thread-id")
    if isinstance(thread_id, str):
        thread_id = thread_id.strip()
        if thread_id:
            print(thread_id)
except Exception:
    pass
PY
  )"
fi

legacy_group=""
if [[ -n "${thread_id:-}" ]]; then
  legacy_group="codex-${thread_id}"
fi

terminal_notifier="$(command -v terminal-notifier || true)"
if [[ -z "${terminal_notifier}" || ! -x "${terminal_notifier}" ]]; then
  for candidate in /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; do
    if [[ -x "${candidate}" ]]; then
      terminal_notifier="${candidate}"
      break
    fi
  done
fi

if [[ -n "${terminal_notifier:-}" && -x "${terminal_notifier}" ]]; then
  "${terminal_notifier}" -remove "${pane_group}" >/dev/null 2>&1 || true
  if [[ -n "${legacy_group:-}" ]]; then
    "${terminal_notifier}" -remove "${legacy_group}" >/dev/null 2>&1 || true
  fi
fi

if [[ "${marker_exists}" == "1" ]]; then
  rm -f "${marker_path}" 2>/dev/null || true
fi

has_marker="0"
while IFS= read -r other_pane_id; do
  [[ -n "${other_pane_id:-}" ]] || continue
  if [[ -f "${turn_complete_dir}/$(safe_key "${other_pane_id}")" ]]; then
    has_marker="1"
    break
  fi
done < <(tmux list-panes -t "${window_id}" -F '#{pane_id}' 2>/dev/null || true)

if [[ "${has_marker}" == "1" ]]; then
  tmux set-window-option -t "${window_id}" @codex_done 1 2>/dev/null || true
else
  tmux set-window-option -t "${window_id}" -u @codex_done 2>/dev/null || true
fi
