#!/usr/bin/env bash
set -euo pipefail

pane_id="${1:-}"
[[ -n "${pane_id}" ]] || exit 0

# Read and discard pane output, but periodically try to mark the window as unread.
# Keep this lightweight: do not run tmux/ps on every line.
check_every="${TMUX_PANE_OUTPUT_WATCH_EVERY:-20}"
if [[ -z "${check_every}" || ! "${check_every}" =~ ^[0-9]+$ || "${check_every}" -le 0 ]]; then
  check_every=20
fi

chunk_size="${TMUX_PANE_OUTPUT_WATCH_CHUNK_SIZE:-256}"
if [[ -z "${chunk_size}" || ! "${chunk_size}" =~ ^[0-9]+$ || "${chunk_size}" -le 0 ]]; then
  chunk_size=256
fi

ignore_max_checks="${TMUX_UNREAD_IGNORE_MAX_CHECKS:-3}"
if [[ -z "${ignore_max_checks}" || ! "${ignore_max_checks}" =~ ^[0-9]+$ || "${ignore_max_checks}" -le 0 ]]; then
  ignore_max_checks=3
fi
ignore_recheck_seconds="${TMUX_UNREAD_IGNORE_RECHECK_SECONDS:-5}"
if [[ -z "${ignore_recheck_seconds}" || ! "${ignore_recheck_seconds}" =~ ^[0-9]+$ || "${ignore_recheck_seconds}" -le 0 ]]; then
  ignore_recheck_seconds=5
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import os
import subprocess
import sys
import time

pane_id = sys.argv[1]
check_every = int(sys.argv[2])
chunk_size = int(sys.argv[3])
ignore_max_checks = int(sys.argv[4])
ignore_recheck_seconds = int(sys.argv[5])

def tmux_show(option: str) -> str:
  try:
    res = subprocess.run(
      ["tmux", "show", "-p", "-t", pane_id, "-qv", option],
      stdout=subprocess.PIPE,
      stderr=subprocess.DEVNULL,
      text=True,
      check=False,
    )
    return (res.stdout or "").strip()
  except Exception:
    return ""

mark_cmd = os.path.expanduser("~/.config/tmux/scripts/mark_unread_activity.sh")

tick_n = 0
while True:
  try:
    data = os.read(0, chunk_size)
  except InterruptedError:
    continue

  if not data:
    break

  tick_n += 1
  if tick_n != 1 and (tick_n % check_every) != 0:
    continue

  pane_ignored = tmux_show("@unread_ignore_activity")
  if pane_ignored == "1":
    continue

  pane_unread = tmux_show("@unread_pane_activity")
  pane_checked = tmux_show("@unread_ignore_checked")
  if pane_unread == "1" and pane_checked == "1":
    pane_check_count = tmux_show("@unread_ignore_check_count")
    pane_checked_at = tmux_show("@unread_ignore_checked_at")
    try:
      check_count = int(pane_check_count)
    except Exception:
      check_count = 0
    try:
      checked_at = int(pane_checked_at)
    except Exception:
      checked_at = 0

    if check_count >= ignore_max_checks:
      continue
    now_s = int(time.time())
    if checked_at > 0 and (now_s - checked_at) < ignore_recheck_seconds:
      continue

  try:
    subprocess.run([mark_cmd, "", pane_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
  except Exception:
    pass
' "${pane_id}" "${check_every}" "${chunk_size}" "${ignore_max_checks}" "${ignore_recheck_seconds}" >/dev/null 2>&1 || true
  exit 0
fi

# Fallback: only triggers on \n/\r output (line-based).
line_n=0
tr '\r' '\n' | while IFS= read -r _line; do
  line_n=$((line_n + 1))
  if (( line_n == 1 || line_n % check_every == 0 )); then
    pane_ignored="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_activity 2>/dev/null || true)"
    if [[ "${pane_ignored:-0}" == "1" ]]; then
      continue
    fi

    pane_unread="$(tmux show -p -t "${pane_id}" -qv @unread_pane_activity 2>/dev/null || true)"
    pane_checked="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_checked 2>/dev/null || true)"
    if [[ "${pane_unread:-0}" == "1" && "${pane_checked:-0}" == "1" ]]; then
      pane_check_count="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_check_count 2>/dev/null || true)"
      pane_checked_at="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_checked_at 2>/dev/null || true)"
      if [[ -z "${pane_check_count:-}" || ! "${pane_check_count}" =~ ^[0-9]+$ ]]; then
        pane_check_count=0
      fi
      if [[ -z "${pane_checked_at:-}" || ! "${pane_checked_at}" =~ ^[0-9]+$ ]]; then
        pane_checked_at=0
      fi
      if (( pane_check_count >= ignore_max_checks )); then
        continue
      fi
      now_s="$(date +%s 2>/dev/null || echo 0)"
      if [[ -z "${now_s:-}" || ! "${now_s}" =~ ^[0-9]+$ ]]; then
        now_s=0
      fi
      if (( now_s > 0 && (now_s - pane_checked_at) < ignore_recheck_seconds )); then
        continue
      fi
    fi

    ~/.config/tmux/scripts/mark_unread_activity.sh "" "${pane_id}" >/dev/null 2>&1 || true
  fi
done
