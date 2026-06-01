#!/usr/bin/env bash
set -euo pipefail

trim_final_newline=0
for arg in "$@"; do
  case "$arg" in
    --trim-final-newline)
      trim_final_newline=1
      ;;
    *)
      printf 'usage: %s [--trim-final-newline]\n' "${0##*/}" >&2
      exit 2
      ;;
  esac
done

read_clipboard() {
  if command -v pbpaste >/dev/null 2>&1; then
    pbpaste
    return 0
  fi
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste --no-newline 2>/dev/null || wl-paste
    return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o 2>/dev/null || true
    return 0
  fi
  if command -v xsel >/dev/null 2>&1; then
    xsel -o --clipboard 2>/dev/null || true
    return 0
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command Get-Clipboard 2>/dev/null || true
    return 0
  fi
  return 1
}

tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-clipboard.XXXXXX")
norm_tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-clipboard-normalized.XXXXXX")
trap 'rm -f "$tmp" "$norm_tmp"' EXIT

read_clipboard >"$tmp" || true
if [[ ! -s "$tmp" ]]; then
  exit 0
fi

# normalize CRLF -> LF
tr -d '\r' <"$tmp" >"$norm_tmp"
mv "$norm_tmp" "$tmp"

if [[ "$trim_final_newline" -eq 1 ]]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$tmp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
if data.endswith(b"\n"):
    path.write_bytes(data[:-1])
PY
  elif command -v perl >/dev/null 2>&1; then
    perl -0pi -e 's/\n\z//' "$tmp"
  else
    printf 'paste_from_clipboard.sh: need python3 or perl for --trim-final-newline\n' >&2
    exit 1
  fi
fi

tmux load-buffer "$tmp"
tmux paste-buffer -p -d
