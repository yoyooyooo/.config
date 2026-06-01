#!/usr/bin/env bash
set -euo pipefail

socket_path=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--socket" && $((i + 1)) -lt ${#args[@]} ]]; then
    socket_path="${args[$((i + 1))]}"
    break
  fi
done

tmux_args=()
if [[ -n "$socket_path" ]]; then
  tmux_args=(-S "$socket_path")
fi

tmux_get() {
  tmux "${tmux_args[@]}" show-option -gqv "$1" 2>/dev/null || true
}

debug_log() {
  if [[ "${CODEX_TMUX_PROGRESS_RESOLVE_DEBUG:-0}" == "1" ]]; then
    printf '%s\n' "$*" >&2
  fi
}

cache_ttl="${CODEX_TMUX_PROGRESS_RESOLVE_TTL:-60}"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tmux"
cache_file="${cache_dir}/codex-tmux-progress-root"

now_epoch() {
  date +%s
}

fresh_cache_root() {
  [[ -f "$cache_file" ]] || return 1
  local now cached_at cached_root
  now="$(now_epoch)"
  IFS=$'\t' read -r cached_at cached_root <"$cache_file" || return 1
  [[ "$cached_at" =~ ^[0-9]+$ ]] || return 1
  [[ "$cache_ttl" =~ ^[0-9]+$ ]] || cache_ttl=60
  if (( now - cached_at > cache_ttl )); then
    return 1
  fi
  valid_root "$cached_root" || return 1
  printf '%s\n' "$cached_root"
}

write_cache_root() {
  local root="$1"
  mkdir -p "$cache_dir" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(now_epoch)" "$root" >"${cache_file}.$$" 2>/dev/null || return 0
  mv "${cache_file}.$$" "$cache_file" 2>/dev/null || true
}

resolve_latest_root() {
  local parent="$1"
  [[ -d "$parent" ]] || return 1
  python3 - "$parent" <<'PY'
from pathlib import Path
import re
import sys

parent = Path(sys.argv[1]).expanduser()

def key(path: Path):
    parts = []
    for item in re.split(r"([0-9]+)", path.name):
        if item.isdigit():
            parts.append((1, int(item)))
        else:
            parts.append((0, item))
    return parts

candidates = [
    path
    for path in parent.iterdir()
    if path.is_dir() and (path / "scripts" / "codex_tmux_progress.py").is_file()
]
if not candidates:
    raise SystemExit(1)
print(max(candidates, key=key))
PY
}

valid_root() {
  [[ -n "${1:-}" && -f "$1/scripts/codex_tmux_progress.py" ]]
}

version_parent() {
  local root="$1"
  local parent
  parent="$(dirname "$root")"
  if [[ -d "$parent" && "$(basename "$parent")" == "codex-tmux-progress" ]]; then
    printf '%s\n' "$parent"
  fi
}

resolve_root() {
  local root="$1"
  local parent
  parent="$(version_parent "$root")"
  if [[ -n "$parent" ]]; then
    resolve_latest_root "$parent" 2>/dev/null && return 0
  fi
  valid_root "$root" && printf '%s\n' "$root"
}

configured_root="$(tmux_get @codex_tmux_progress_dev_root)"
if [[ -z "$configured_root" ]]; then
  configured_root="$(tmux_get @codex_tmux_progress_root)"
fi
plugin_root="$(resolve_root "$configured_root" 2>/dev/null || true)"
if valid_root "$plugin_root"; then
  debug_log "codex-tmux-progress resolver: configured root $plugin_root"
else
  plugin_root="$(fresh_cache_root 2>/dev/null || true)"
  if valid_root "$plugin_root"; then
    debug_log "codex-tmux-progress resolver: cache hit $plugin_root"
  else
    debug_log "codex-tmux-progress resolver: cache miss"
  fi
fi
if ! valid_root "$plugin_root"; then
  fallback_root="$(tmux_get @codex_tmux_progress_fallback_root)"
  plugin_root="$(resolve_latest_root "$fallback_root" 2>/dev/null || true)"
fi
if valid_root "$plugin_root"; then
  write_cache_root "$plugin_root"
fi

state_root="$(tmux_get @codex_tmux_progress_state_root)"
if [[ -z "$state_root" ]]; then
  state_root="$(tmux_get @codex_tmux_progress_fallback_state_root)"
fi

if ! valid_root "$plugin_root" || [[ -z "$state_root" ]]; then
  exit 0
fi

CODEX_TMUX_PROGRESS_STATE_ROOT="$state_root" \
PLUGIN_ROOT="$plugin_root" \
python3 "$plugin_root/scripts/codex_tmux_progress.py" "$@"
