#!/usr/bin/env bash
set -euo pipefail

line="${1:-}"
range="${2:-}"
x="${3:-}"
y="${4:-}"
client_tty="${5:-}"
log_file="${HOME}/.config/tmux/run/status-click.log"

mkdir -p "$(dirname "$log_file")" 2>/dev/null || exit 0
{
  printf '%s line=%s range=%s x=%s y=%s tty=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line" "$range" "$x" "$y" "$client_tty"
} >>"$log_file" 2>/dev/null || exit 0

if tail -n 80 "$log_file" >"${log_file}.$$" 2>/dev/null; then
  mv "${log_file}.$$" "$log_file" 2>/dev/null || true
else
  rm -f "${log_file}.$$" 2>/dev/null || true
fi
