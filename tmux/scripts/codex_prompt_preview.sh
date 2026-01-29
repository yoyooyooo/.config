#!/usr/bin/env bash
set -euo pipefail

file="${1:-}"
file="${file%$'\r'}"
if [[ "$file" == \'*\' ]]; then
  file="${file:1:${#file}-2}"
elif [[ "$file" == \"*\" ]]; then
  file="${file:1:${#file}-2}"
fi

if [[ -z "${file:-}" ]]; then
  exit 0
fi

if [[ ! -f "$file" ]]; then
  printf '%s\n' "not a file: $file"
  exit 0
fi

if command -v bat >/dev/null 2>&1; then
  exec bat --paging=never --style=numbers --color=always --line-range=:400 -- "$file"
fi

exec sed -n '1,200p' "$file"
