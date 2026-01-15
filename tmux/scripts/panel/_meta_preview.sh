#!/usr/bin/env bash
set -euo pipefail

path="${1:-}"
if [[ -z "$path" || ! -f "$path" ]]; then
  exit 0
fi

awk '
  NR==1 && /^#!/ { next }
  /^#[[:space:]]*(desc|usage|keys|note):/ {
    line=$0
    sub(/^#[[:space:]]*/, "", line)
    print line
    next
  }
  /^#$/ { next }
  /^#/ { next }
  { exit }
' "$path"
