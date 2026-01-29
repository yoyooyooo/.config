#!/usr/bin/env bash
set -euo pipefail

# Best-effort: switch input method to English (macOS).
# Requires one of:
#   - macism:   https://github.com/laishulu/macism
#   - im-select https://github.com/daipeihust/im-select
#
# Configuration:
#   - pass the target input source id as $1, or
#   - set tmux option: @input_method_english_id (e.g. com.apple.keylayout.ABC)

if [[ "$(uname -s)" != "Darwin" ]]; then
  exit 0
fi

english_source_id="${1:-}"
if [[ -z "${english_source_id}" ]] && command -v tmux >/dev/null 2>&1; then
  english_source_id="$(tmux show-option -gqv @input_method_english_id 2>/dev/null || true)"
fi
if [[ -z "${english_source_id}" ]]; then
  english_source_id="com.apple.keylayout.ABC"
fi

macism_bin=""
if command -v macism >/dev/null 2>&1; then
  macism_bin="$(command -v macism)"
elif [[ -x /opt/homebrew/bin/macism ]]; then
  macism_bin="/opt/homebrew/bin/macism"
elif [[ -x /usr/local/bin/macism ]]; then
  macism_bin="/usr/local/bin/macism"
fi

if [[ -n "${macism_bin}" ]]; then
  current_id="$("${macism_bin}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${current_id}" && "${current_id}" == "${english_source_id}" ]]; then
    exit 0
  fi
  "${macism_bin}" "${english_source_id}" >/dev/null 2>&1 || true
  exit 0
fi

im_select_bin=""
if command -v im-select >/dev/null 2>&1; then
  im_select_bin="$(command -v im-select)"
elif [[ -x /opt/homebrew/bin/im-select ]]; then
  im_select_bin="/opt/homebrew/bin/im-select"
elif [[ -x /usr/local/bin/im-select ]]; then
  im_select_bin="/usr/local/bin/im-select"
fi

if [[ -n "${im_select_bin}" ]]; then
  current_id="$("${im_select_bin}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${current_id}" && "${current_id}" == "${english_source_id}" ]]; then
    exit 0
  fi
  "${im_select_bin}" "${english_source_id}" >/dev/null 2>&1 || true
  exit 0
fi

exit 0
