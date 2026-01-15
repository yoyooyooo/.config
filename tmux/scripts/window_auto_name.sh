#!/usr/bin/env bash
set -euo pipefail

# Prefer: git branch > repo name > last directory name
path="${1:-$PWD}"

fallback_dir() {
  local last_dir
  last_dir="${path##*/}"
  [[ -n "$last_dir" ]] && printf '%s' "$last_dir" || printf '%s' "$path"
}

if ! command -v git >/dev/null 2>&1; then
  fallback_dir
  exit 0
fi

top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$top" ]]; then
  fallback_dir
  exit 0
fi

branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ -n "$branch" ]]; then
  printf '%s' "$branch"
  exit 0
fi

repo="${top##*/}"
if [[ -n "$repo" ]]; then
  printf '%s' "$repo"
  exit 0
fi

fallback_dir
