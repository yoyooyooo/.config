#!/usr/bin/env bash
set -euo pipefail

# Args: <pane_id> <pane_pid> <pane_width> <pane_path> <pane_cmd>
pane_id="${1:-}"
pid="${2:-}"
width="${3:-80}"
pane_path="${4:-$PWD}"
pane_cmd="${5:-}"
cache_ttl="${TMUX_PANE_TITLE_CACHE_TTL:-2}"
cache_dir="${HOME}/.config/tmux/run/pane-title-cache"

get_mtime() {
  local f="$1"
  if command -v stat >/dev/null 2>&1; then
    stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

safe_key() {
  local value="$1"
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value//../__}"
  printf '%s' "$value"
}

cache_key="${pane_id}|${pid}|${width}|${pane_path}|${pane_cmd}"
cache_file=""
cache_key_file=""
if [[ -n "${pane_id}" ]]; then
  mkdir -p "${cache_dir}" >/dev/null 2>&1 || true
  cache_file="${cache_dir}/$(safe_key "${pane_id}").title"
  cache_key_file="${cache_dir}/$(safe_key "${pane_id}").key"
  if [[ -f "${cache_file}" && -f "${cache_key_file}" ]]; then
    current_key="$(tr -d '\n' <"${cache_key_file}" 2>/dev/null || true)"
    cache_mtime="$(get_mtime "${cache_file}")"
    now_s="$(date +%s)"
    if [[ "${current_key}" == "${cache_key}" && "${cache_mtime}" =~ ^[0-9]+$ && "${cache_ttl}" =~ ^[0-9]+$ ]]; then
      if (( now_s - cache_mtime < cache_ttl )); then
        cat "${cache_file}"
        exit 0
      fi
    fi
  fi
fi

# Best-effort: inherit venv/conda from the pane's process env
if [[ -n "$pid" ]]; then
  ps_line=$(ps e -p "$pid" -o command= 2>/dev/null || true)
  if [[ -n "$ps_line" ]]; then
    venv=$(printf '%s' "$ps_line" | sed -n 's/.*[[:space:]]VIRTUAL_ENV=\([^[:space:]]*\).*/\1/p' | tail -n1)
    conda_env=$(printf '%s' "$ps_line" | sed -n 's/.*[[:space:]]CONDA_DEFAULT_ENV=\([^[:space:]]*\).*/\1/p' | tail -n1)
    conda_prefix=$(printf '%s' "$ps_line" | sed -n 's/.*[[:space:]]CONDA_PREFIX=\([^[:space:]]*\).*/\1/p' | tail -n1)
    [[ -n "$venv" ]] && export VIRTUAL_ENV="$venv"
    [[ -n "$conda_env" ]] && export CONDA_DEFAULT_ENV="$conda_env"
    [[ -n "$conda_prefix" ]] && export CONDA_PREFIX="$conda_prefix"
  fi
fi

strip_wrappers() {
  # 1) strip ANSI, 2) strip bash \[\] and zsh %{ %}
  perl -pe 's/\e\[[\d;]*[[:alpha:]]//g' | sed -E 's/\\\[|\\\]//g; s/%\{|%\}//g'
}

run_starship() {
  local cfg
  cfg="${STARSHIP_TMUX_CONFIG:-$HOME/.config/tmux/starship-tmux.toml}"
  STARSHIP_LOG=error STARSHIP_CONFIG="$cfg" \
    starship prompt --terminal-width "$width" | strip_wrappers | tr -d '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

fallback() {
  # <cmd> — <last dir>
  local last_dir
  last_dir="${pane_path##*/}"
  printf '%s — %s' "$pane_cmd" "$last_dir"
}

if command -v starship >/dev/null 2>&1; then
  title="$(cd "$pane_path" && run_starship)" || title="$(fallback)"
else
  title="$(fallback)"
fi

if [[ -n "${cache_file}" && -n "${cache_key_file}" ]]; then
  tmp_title="${cache_file}.$$"
  tmp_key="${cache_key_file}.$$"
  printf '%s' "${title}" >"${tmp_title}" 2>/dev/null || true
  printf '%s' "${cache_key}" >"${tmp_key}" 2>/dev/null || true
  mv -f "${tmp_title}" "${cache_file}" 2>/dev/null || true
  mv -f "${tmp_key}" "${cache_key_file}" 2>/dev/null || true
fi

printf '%s' "${title}"
