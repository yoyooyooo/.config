#!/usr/bin/env bash
set -euo pipefail

panel_dir="${TMUX_PANEL_DIR:-$HOME/.config/tmux/scripts/panel}"
local_panel_dir="${TMUX_PANEL_LOCAL_DIR:-$HOME/.config/tmux/local/scripts/panel}"
ext_panel_dir="${TMUX_PANEL_EXT_DIR:-$HOME/.config/tmux/extensions/codex/scripts/panel}"
panel_meta_preview="${TMUX_PANEL_META_PREVIEW:-$panel_dir/_meta_preview.sh}"
self_name="$(basename "${BASH_SOURCE[0]}")"

origin_pane_id="$(tmux show -gqv @panel_origin_pane_id 2>/dev/null || true)"
origin_client="$(tmux show -gqv @panel_origin_client 2>/dev/null || true)"

if [[ -z "${ORIGIN_PANE_ID:-}" || "${ORIGIN_PANE_ID:-}" == *"#{"* || "${ORIGIN_PANE_ID:-}" != %* ]]; then
  if [[ -n "${origin_pane_id:-}" && "$origin_pane_id" == %* ]]; then
    export ORIGIN_PANE_ID="$origin_pane_id"
  fi
fi

if [[ -z "${ORIGIN_CLIENT:-}" || "${ORIGIN_CLIENT:-}" == *"#{"* ]]; then
  if [[ -n "${origin_client:-}" ]]; then
    export ORIGIN_CLIENT="$origin_client"
  fi
fi

script_meta() {
  local path="$1"
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
}

script_desc_one_line() {
  local path="$1"
  local desc
  desc="$(
    awk '
      NR==1 && /^#!/ { next }
      /^#[[:space:]]*desc:[[:space:]]*/ {
        line=$0
        sub(/^#[[:space:]]*desc:[[:space:]]*/, "", line)
        print line
        exit
      }
      /^#/ { next }
      { exit }
    ' "$path"
  )"
  if [[ -z "${desc:-}" ]]; then
    desc="(无描述：在脚本头部加 # desc: ...)"
  fi
  printf '%s' "$desc"
}

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

if ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' "fzf 未安装：请先安装 fzf（脚本面板依赖 fzf）。"
  pause
  exit 0
fi

panel_dirs=()
if [[ -d "$panel_dir" ]]; then
  panel_dirs+=("$panel_dir")
fi
if [[ "${TMUX_ENABLE_CODEX:-0}" == "1" && -d "$ext_panel_dir" ]]; then
  panel_dirs+=("$ext_panel_dir")
fi
if [[ -d "$local_panel_dir" ]]; then
  panel_dirs+=("$local_panel_dir")
fi

if ((${#panel_dirs[@]} == 0)); then
  printf '%s\n' "目录不存在：$panel_dir"
  pause
  exit 0
fi

shopt -s nullglob
items=()
for dir in "${panel_dirs[@]}"; do
  for path in "$dir"/*; do
    [[ -f "$path" && -x "$path" ]] || continue
    base="$(basename "$path")"
    [[ "$base" == "$self_name" ]] && continue
    [[ "$base" == _* ]] && continue
    items+=("$base"$'\t'"$(script_desc_one_line "$path")"$'\t'"$path")
  done
done

if ((${#items[@]} == 0)); then
  printf '%s\n' "未发现可执行脚本：${panel_dirs[*]}"
  printf '%s\n' "提示：把脚本放进上述目录并 chmod +x；脚本会自动出现在面板里。"
  pause
  exit 0
fi

selected="$(
  printf '%s\n' "${items[@]}" | fzf \
    --reverse \
    --exit-0 \
    --delimiter=$'\t' \
    --with-nth=1,2 \
    --prompt='panel> ' \
    --preview "printf '%s\n\n' {3}; bash \"${panel_meta_preview}\" {3} || true" \
    --preview-window='down,70%,wrap'
)" || true

if [[ -z "${selected:-}" ]]; then
  exit 0
fi

script_path="${selected##*$'\t'}"
exec "$script_path"
