#!/usr/bin/env bash
# desc: manage skills (enable/disable via mv between ~/.codex/skills and ~/.agents/skills)
# usage: fzf popup; Enter toggle, Ctrl-e enable, Ctrl-d disable, Ctrl-r reload
# keys: Enter toggle | Ctrl-e enable | Ctrl-d disable | Ctrl-r reload | Tab multi
set -euo pipefail

# shellcheck disable=SC1090
if [[ -f "$HOME/.config/tmux/scripts/lib/tmux_kit_proxy.sh" ]]; then
  source "$HOME/.config/tmux/scripts/lib/tmux_kit_proxy.sh"
fi

self="${BASH_SOURCE[0]}"
enabled_dir="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
disabled_dir="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
status_width="${SKILLS_STATUS_WIDTH:-8}"
name_width="${SKILLS_NAME_WIDTH:-28}"
color_enabled="${SKILLS_COLOR_ENABLED:-$'\033[32m'}"
color_disabled="${SKILLS_COLOR_DISABLED:-$'\033[31m'}"
color_reset="${SKILLS_COLOR_RESET:-$'\033[0m'}"

enabled_dir="${enabled_dir%/}"
disabled_dir="${disabled_dir%/}"
if [[ ! "${status_width:-}" =~ ^[0-9]+$ ]]; then
  status_width=8
fi
if [[ ! "${name_width:-}" =~ ^[0-9]+$ ]]; then
  name_width=28
fi

pause() {
  read -r -n 1 -s -p "Press any key to close..." || true
  printf '\n'
}

require_fzf() {
  if ! command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "fzf not found. Please install fzf."
    pause
    exit 0
  fi
}

extract_desc() {
  local file="$1"
  local desc=""
  if [[ -f "$file" ]]; then
    desc="$(
      awk '
        BEGIN { in_yaml=0 }
        /^---[[:space:]]*$/ { if (in_yaml==0) { in_yaml=1; next } else { exit } }
        in_yaml==1 && /^description:[[:space:]]*/ {
          sub(/^description:[[:space:]]*/, "", $0)
          print
          exit
        }
      ' "$file"
    )"
    desc="${desc%\"}"
    desc="${desc#\"}"
  fi
  if [[ -z "${desc:-}" ]]; then
    desc="-"
  fi
  printf '%s' "$desc"
}

sanitize_field() {
  local text="${1:-}"
  text="${text//$'\t'/ }"
  text="${text//$'\n'/ }"
  printf '%s' "$text"
}

pad_fixed() {
  local width="$1"
  local text="${2:-}"
  printf "%-${width}.${width}s" "$text"
}

format_display_line() {
  local status="${1:-}"
  local name="${2:-}"
  local desc="${3:-}"
  local status_pad name_pad status_color status_display

  status="$(sanitize_field "$status")"
  name="$(sanitize_field "$name")"
  desc="$(sanitize_field "$desc")"
  status_pad="$(pad_fixed "$status_width" "$status")"
  name_pad="$(pad_fixed "$name_width" "$name")"

  status_color=""
  case "$status" in
    ENABLED) status_color="$color_enabled" ;;
    DISABLED) status_color="$color_disabled" ;;
  esac
  if [[ -n "${status_color:-}" ]]; then
    status_display="${status_color}${status_pad}${color_reset}"
  else
    status_display="$status_pad"
  fi

  printf '%s  %s %s' "$status_display" "$name_pad" "$desc"
}

list_dir() {
  local dir="$1"
  local status="$2"
  [[ -d "$dir" ]] || return 0

  while IFS= read -r -d '' path; do
    local name desc display_line
    name="$(basename "$path")"
    [[ "$name" == .* ]] && continue
    [[ -f "$path/SKILL.md" ]] || continue
    desc="$(extract_desc "$path/SKILL.md")"
    display_line="$(format_display_line "$status" "$name" "$desc")"
    printf '%s\t%s\t%s\t%s\n' "$display_line" "$status" "$name" "$path"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
}

list_items() {
  local order_file="${SKILLS_ORDER_FILE:-}"
  if [[ -n "${order_file:-}" && -f "$order_file" ]]; then
    local tmp
    tmp="$(mktemp -t tmux-skills-items-XXXXXX)"
    list_dir "$enabled_dir" "ENABLED" >"$tmp"
    list_dir "$disabled_dir" "DISABLED" >>"$tmp"
    awk -F '\t' -v order_file="$order_file" '
      BEGIN {
        while ((getline < order_file) > 0) {
          name=$0
          if (name != "") {
            order[++order_count]=name
          }
        }
        close(order_file)
      }
      {
        name=$3
        lines[name]=$0
      }
      END {
        for (i=1; i<=order_count; i++) {
          name=order[i]
          if (name in lines) {
            print lines[name]
            printed[name]=1
          }
        }
        for (name in lines) {
          if (!(name in printed)) {
            print lines[name]
          }
        }
      }
    ' "$tmp"
    rm -f "$tmp"
    return
  fi

  list_dir "$enabled_dir" "ENABLED"
  list_dir "$disabled_dir" "DISABLED"
}

preview_item() {
  local status="${1:-}"
  local name="${2:-}"
  local path="${3:-}"
  local file="${path%/}/SKILL.md"

  printf '%s\n' "STATUS: $status"
  printf '%s\n' "NAME:   $name"
  printf '%s\n' "PATH:   $path"
  printf '%s\n' "----"

  if [[ ! -f "$file" ]]; then
    printf '%s\n' "SKILL.md not found."
    return 0
  fi

  if command -v bat >/dev/null 2>&1; then
    bat --style=plain --color=always --paging=never "$file"
  else
    sed -n '1,200p' "$file"
  fi
}

display_msg() {
  local msg="$1"
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    tmux display-message "$msg" >/dev/null 2>&1 || true
  fi
}

move_items() {
  local mode="$1"
  shift || true
  local moved=0
  local skipped=0

  if [[ $# -eq 0 ]]; then
    return 0
  fi

  for path in "$@"; do
    [[ -n "${path:-}" ]] || continue
    [[ -d "$path" ]] || { skipped=$((skipped + 1)); continue; }
    [[ -f "$path/SKILL.md" ]] || { skipped=$((skipped + 1)); continue; }

    local name src_state dst_root dst
    name="$(basename "$path")"
    src_state=""
    if [[ "$path" == "$enabled_dir/"* ]]; then
      src_state="ENABLED"
    elif [[ "$path" == "$disabled_dir/"* ]]; then
      src_state="DISABLED"
    fi

    if [[ -z "$src_state" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    case "$mode" in
      enable)
        [[ "$src_state" == "DISABLED" ]] || { skipped=$((skipped + 1)); continue; }
        dst_root="$enabled_dir"
        ;;
      disable)
        [[ "$src_state" == "ENABLED" ]] || { skipped=$((skipped + 1)); continue; }
        dst_root="$disabled_dir"
        ;;
      toggle)
        if [[ "$src_state" == "ENABLED" ]]; then
          dst_root="$disabled_dir"
        else
          dst_root="$enabled_dir"
        fi
        ;;
      *)
        skipped=$((skipped + 1))
        continue
        ;;
    esac

    mkdir -p "$dst_root"
    dst="${dst_root%/}/$name"
    if [[ -e "$dst" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    mv "$path" "$dst"
    moved=$((moved + 1))
  done

  display_msg "skills: moved=$moved skipped=$skipped"
}

run_fzf() {
  require_fzf

  local list_cmd items header
  list_cmd="bash $self list"
  items="$($list_cmd || true)"

  if [[ -z "${items:-}" ]]; then
    printf '%s\n' "No skills found."
    printf '%s\n' "Expected: $enabled_dir/*/SKILL.md or $disabled_dir/*/SKILL.md"
    pause
    exit 0
  fi

  if command -v mktemp >/dev/null 2>&1; then
    export SKILLS_ORDER_FILE
    SKILLS_ORDER_FILE="$(mktemp -t tmux-skills-order-XXXXXX)"
    printf '%s\n' "$items" | awk -F $'\t' '{print $3}' >"$SKILLS_ORDER_FILE"
    cleanup_order_file() {
      [[ -n "${SKILLS_ORDER_FILE:-}" ]] && rm -f "$SKILLS_ORDER_FILE" 2>/dev/null || true
    }
    trap cleanup_order_file EXIT INT TERM HUP
  fi

  header=$'Enter=toggle  Ctrl-e=enable  Ctrl-d=disable  Ctrl-r=reload  Tab=multi  Ctrl-a=all  Ctrl-x=none\nENABLED: '"$enabled_dir"$'  DISABLED: '"$disabled_dir"

  printf '%s\n' "$items" | fzf \
    --multi \
    --reverse \
    --exit-0 \
    --no-sort \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='skills> ' \
    --header="$header" \
    --preview "bash $self preview {2} {3} {4}" \
    --preview-window='down,70%,wrap,follow' \
    --bind "enter:execute-silent(bash $self toggle {+4})+reload($list_cmd)" \
    --bind "ctrl-e:execute-silent(bash $self enable {+4})+reload($list_cmd)" \
    --bind "ctrl-d:execute-silent(bash $self disable {+4})+reload($list_cmd)" \
    --bind "ctrl-r:reload($list_cmd)" \
    --bind "ctrl-a:select-all" \
    --bind "ctrl-x:deselect-all"
}

cmd="${1:-}"
case "$cmd" in
  list)
    list_items
    ;;
  preview)
    shift || true
    preview_item "$@"
    ;;
  enable|disable|toggle)
    shift || true
    move_items "$cmd" "$@"
    ;;
  *)
    run_fzf
    ;;
esac

