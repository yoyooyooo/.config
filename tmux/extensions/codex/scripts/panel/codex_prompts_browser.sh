#!/usr/bin/env bash
# desc: Codex prompts 双栏浏览（左筛文件路径，右侧全文检索/卡片；Enter 粘贴）
# usage: ORIGIN_PANE_ID=<pane_id> [CODEX_PROMPTS_DIR=~/.codex/prompts] bash ~/.config/tmux/extensions/codex/scripts/panel/codex_prompts_browser.sh
# keys:
#   Left:  Tab=Fixed/Regex  Enter=粘贴并关闭  Esc/C-c=关闭
#   Right: Tab=Fixed/Regex  Enter=从卡片进入文件预览  Esc=清空搜索/解除锁定  C-r=刷新
set -euo pipefail

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

die() {
  printf '%s\n' "$1"
  pause
  exit 0
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

outer_socket_detect() {
  local outer_socket="${OUTER_TMUX_SOCKET:-}"
  if [[ -z "$outer_socket" && -n "${TMUX:-}" ]]; then
    outer_socket="${TMUX%%,*}"
  fi
  printf '%s' "$outer_socket"
}

tmux_outer() {
  local outer_socket
  outer_socket="$(outer_socket_detect)"
  if [[ -n "${outer_socket:-}" ]]; then
    command tmux -S "$outer_socket" "$@"
    return
  fi
  command tmux "$@"
}

tmux_nested() {
  local nested_server="${NESTED_SERVER:-}"
  if [[ -n "${nested_server:-}" ]]; then
    command tmux -L "$nested_server" "$@"
    return
  fi
  command tmux "$@"
}

state_dir_required() {
  if [[ -z "${STATE_DIR:-}" || ! -d "${STATE_DIR:-}" ]]; then
    die "STATE_DIR 未设置或不存在（仅供内部调用）。"
  fi
}

state_read() {
  local key="$1"
  local default="${2:-}"
  local path="$STATE_DIR/$key"
  if [[ -f "$path" ]]; then
    cat "$path"
    return 0
  fi
  printf '%s' "$default"
}

state_write() {
  local key="$1"
  local value="${2:-}"
  local tmp="$STATE_DIR/.tmp.${key}.$$.$RANDOM"
  printf '%s' "$value" >"$tmp"
  mv -f "$tmp" "$STATE_DIR/$key"
}

state_write_lines() {
  local key="$1"
  local tmp="$STATE_DIR/.tmp.${key}.$$.$RANDOM"
  cat >"$tmp"
  mv -f "$tmp" "$STATE_DIR/$key"
}

list_md_files() {
  local prompts_dir="$1"
  if require_cmd fd; then
    fd --type f --extension md --absolute-path . "$prompts_dir" 2>/dev/null
    return
  fi
  find "$prompts_dir" -type f -name '*.md' -print 2>/dev/null
}

strip_yaml_front_matter() {
  local file="$1"
  awk '
    BEGIN {
      maybe = 0
      in_front_matter = 0
      closed = 0
      n = 0
    }
    NR == 1 {
      if ($0 ~ /^---[[:space:]]*$/) {
        maybe = 1
        in_front_matter = 1
        buf[++n] = $0
        next
      }
    }
    {
      if (maybe && in_front_matter) {
        buf[++n] = $0
        if ($0 ~ /^(---|\\.\\.\\.)[[:space:]]*$/) {
          in_front_matter = 0
          closed = 1
          next
        }
        next
      }

      if (!maybe) {
        print
        next
      }

      if (closed) {
        print
      }
    }
    END {
      if (maybe && !closed) {
        for (i = 1; i <= n; i++) print buf[i]
      }
    }
  ' "$file"
}

trim_edges() {
  awk '
    { lines[NR] = $0 }
    END {
      start = 1
      while (start <= NR && lines[start] ~ /^[[:space:]]*$/) start++
      end = NR
      while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
      if (start > end) exit

      first = lines[start]
      sub(/^[[:space:]]+/, "", first)
      lines[start] = first

      last = lines[end]
      sub(/[[:space:]]+$/, "", last)
      lines[end] = last

      for (i = start; i <= end; i++) print lines[i]
    }
  '
}

ask_arguments() {
  local file="$1"
  local last_arguments="${2:-}"
  local header
  header=$(
    cat <<EOF
检测到占位符：\$ARGUMENTS
文件：$(basename "$file")
输入替换内容，Enter 确认粘贴，Esc 返回上一步
EOF
  )

  local out
  out="$(
    printf '%s\n' "粘贴" | fzf \
      --phony \
      --print-query \
      --exit-0 \
      --height='40%' \
      --layout=reverse \
      --border \
      --info=inline \
      --prompt='arguments> ' \
      --header="$header" \
      --query="$last_arguments"
  )" || return 1

  printf '%s' "${out%%$'\n'*}"
}

paste_file() {
  local file="$1"
  local origin_pane_id="${ORIGIN_PANE_ID:-${2:-}}"
  if [[ -z "${origin_pane_id:-}" ]]; then
    printf '%s\n' "缺少 ORIGIN_PANE_ID（需要从 tmux bind-key 里传入触发 pane_id）。"
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "不是文件：$file"
    return 1
  fi

  local content
  content="$(strip_yaml_front_matter "$file" | trim_edges)"

  local last_arguments
  last_arguments="$(state_read last_arguments "")"

  if [[ "$content" == *'$ARGUMENTS'* ]]; then
    local arguments
    arguments="$(ask_arguments "$file" "$last_arguments")" || return 2
    state_write last_arguments "$arguments"
    content="${content//\$ARGUMENTS/$arguments}"
    content="$(printf '%s\n' "$content" | trim_edges)"
  fi

  local buffer="__codex_prompts_${USER}_$$"
  printf '%s\n' "$content" | tmux_outer load-buffer -b "$buffer" - 2>/dev/null || {
    printf '%s\n' "读取失败：$file"
    return 1
  }

  tmux_outer paste-buffer -p -b "$buffer" -t "$origin_pane_id" 2>/dev/null || {
    tmux_outer delete-buffer -b "$buffer" 2>/dev/null || true
    printf '%s\n' "粘贴失败：目标 pane 不存在或不可用（$origin_pane_id）。"
    return 1
  }

  tmux_outer delete-buffer -b "$buffer" 2>/dev/null || true
  return 0
}

close_popup() {
  tmux_nested kill-server >/dev/null 2>&1 || true
}

left_prompt() {
  state_dir_required
  local mode
  mode="$(state_read left_mode fixed)"
  if [[ "$mode" == "regex" ]]; then
    printf '%s' "files[R]> "
    return 0
  fi
  printf '%s' "files[F]> "
}

right_prompt() {
  state_dir_required
  local mode
  mode="$(state_read right_mode fixed)"
  if [[ "$mode" == "regex" ]]; then
    printf '%s' "right[R]> "
    return 0
  fi
  printf '%s' "right[F]> "
}

left_toggle_mode() {
  state_dir_required
  local mode
  mode="$(state_read left_mode fixed)"
  if [[ "$mode" == "fixed" ]]; then
    state_write left_mode regex
    return 0
  fi
  state_write left_mode fixed
}

right_toggle_mode() {
  state_dir_required
  local mode
  mode="$(state_read right_mode fixed)"
  if [[ "$mode" == "fixed" ]]; then
    state_write right_mode regex
    return 0
  fi
  state_write right_mode fixed
}

left_list() {
  state_dir_required
  local query="${1:-}"
  state_write left_query "$query"

  local all_files="$STATE_DIR/all_files"
  if [[ ! -f "$all_files" ]]; then
    exit 0
  fi

  local tmp="$STATE_DIR/.tmp.left_current_files.$$.$RANDOM"
  local mode
  mode="$(state_read left_mode fixed)"

  if [[ -z "$query" ]]; then
    cat "$all_files" | tee "$tmp"
    mv -f "$tmp" "$STATE_DIR/left_current_files"
    return 0
  fi

  local prompts_dir="${CODEX_PROMPTS_DIR:-$HOME/.codex/prompts}"
  if [[ "$mode" == "regex" ]]; then
    rg -l --no-messages --glob '*.md' -- "$query" "$prompts_dir" 2>/dev/null || true
  else
    rg -l --fixed-strings --no-messages --glob '*.md' -- "$query" "$prompts_dir" 2>/dev/null || true
  fi | sort -u | tee "$tmp"
  mv -f "$tmp" "$STATE_DIR/left_current_files"
}

left_focus() {
  state_dir_required
  local file="${1:-}"
  [[ -n "${file:-}" ]] || return 0

  local prev
  prev="$(state_read left_selected_file "")"
  if [[ "$file" == "$prev" ]]; then
    return 0
  fi

  state_write left_selected_file "$file"

  local right_query
  right_query="$(state_read right_query "")"
  if [[ -z "${right_query:-}" ]]; then
    local right_pane_id="${RIGHT_PANE_ID:-}"
    if [[ -n "${right_pane_id:-}" ]]; then
      tmux_nested send-keys -t "$right_pane_id" C-r >/dev/null 2>&1 || true
    fi
  fi
}

right_clear_lock() {
  state_dir_required
  rm -f "$STATE_DIR/right_locked_file" "$STATE_DIR/right_locked_line" 2>/dev/null || true
}

right_lock_match() {
  state_dir_required
  local item="${1:-}"
  [[ -n "${item:-}" ]] || return 0

  local header="${item%%$'\n'*}"
  header="$(printf '%s' "$header" | sed $'s/\r$//')"

  if [[ "$header" != *:* ]]; then
    return 0
  fi

  local file="${header%:*}"
  local line="${header##*:}"
  if [[ -z "${file:-}" || -z "${line:-}" ]]; then
    return 0
  fi
  if [[ ! "$line" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  state_write right_locked_file "$file"
  state_write right_locked_line "$line"
}

right_enter() {
  state_dir_required
  local item="${1:-}"
  local right_query
  right_query="$(state_read right_query "")"
  if [[ -z "${right_query:-}" ]]; then
    return 0
  fi
  right_lock_match "$item" || true
}

emit0_lines_from_stdin() {
  python3 -c 'import sys; out = sys.stdout.buffer; [out.write(line.rstrip(b"\n") + b"\0") for line in sys.stdin.buffer]'
}

right_list_preview() {
  local file="$1"
  local locked_line="${2:-}"

  if [[ ! -f "$file" ]]; then
    printf '%s\n' "（文件不存在）$file" | emit0_lines_from_stdin
    return 0
  fi

  {
    printf '%s\n' "# $file"
    printf '%s\n' ""

    if require_cmd bat; then
      if [[ -n "${locked_line:-}" && "$locked_line" =~ ^[0-9]+$ ]]; then
        local start end
        start=$((locked_line - 20))
        if ((start < 1)); then start=1; fi
        end=$((locked_line + 200))
        bat --style=numbers --color=always --highlight-line "$locked_line" --line-range "${start}:${end}" -- "$file"
      else
        bat --style=numbers --color=always -- "$file"
      fi
    else
      cat "$file"
    fi
  } | emit0_lines_from_stdin
}

right_list_search() {
  local query="$1"
  local mode
  mode="$(state_read right_mode fixed)"

  local scope_files="$STATE_DIR/left_current_files"
  if [[ ! -s "$scope_files" ]]; then
    scope_files="$STATE_DIR/all_files"
  fi
  if [[ ! -s "$scope_files" ]]; then
    printf '%s\0' "（左侧 scope 为空）"
    return 0
  fi

  if [[ "$mode" == "regex" ]]; then
    python3 -c 'import sys; out = sys.stdout.buffer; [out.write(line.rstrip(b"\n") + b"\0") for line in sys.stdin.buffer]' <"$scope_files" | \
      xargs -0 rg --color=always --heading --line-number -C 5 --no-messages -- "$query" 2>/dev/null || true
  else
    python3 -c 'import sys; out = sys.stdout.buffer; [out.write(line.rstrip(b"\n") + b"\0") for line in sys.stdin.buffer]' <"$scope_files" | \
      xargs -0 rg --color=always --heading --line-number -C 5 --fixed-strings --no-messages -- "$query" 2>/dev/null || true
  fi | python3 -c '
import re
import sys

ansi_re = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(s: str) -> str:
    return ansi_re.sub("", s)


current_file: str | None = None
card_lines: list[str] = []
cards: list[str] = []


def flush_card() -> None:
    global card_lines, cards, current_file
    if not current_file or not card_lines:
        card_lines = []
        return
    line_no: str | None = None
    for line in card_lines:
        plain = strip_ansi(line)
        m = re.match(r"^(\d+):", plain)
        if m:
            line_no = m.group(1)
            break
    if line_no is None:
        card_lines = []
        return
    header = f"{current_file}:{line_no}"
    cards.append(header + "\n\n" + "\n".join(card_lines))
    card_lines = []


for raw in sys.stdin:
    line = raw.rstrip("\n")
    plain = strip_ansi(line).rstrip("\r")
    if plain == "":
        continue
    if plain == "--":
        flush_card()
        continue

    # file header line (rg --heading)
    if not re.match(r"^\d+[:\-]", plain):
        flush_card()
        current_file = plain
        continue

    card_lines.append(line)

flush_card()

if not cards:
    sys.stdout.write("（无匹配）\0")
else:
    for card in cards:
        sys.stdout.write(card + "\0")
'
}

right_list() {
  state_dir_required
  local query="${1:-}"
  state_write right_query "$query"

  if [[ -z "$query" ]]; then
    local locked_file locked_line file
    locked_file="$(state_read right_locked_file "")"
    locked_line="$(state_read right_locked_line "")"
    if [[ -n "${locked_file:-}" ]]; then
      right_list_preview "$locked_file" "$locked_line"
      return 0
    fi

    file="$(state_read left_selected_file "")"
    if [[ -z "${file:-}" ]]; then
      printf '%s\0' "（左侧未选择文件）"
      return 0
    fi

    right_list_preview "$file"
    return 0
  fi

  right_list_search "$query"
}

left_pane() {
  state_dir_required

  local self="${CODEX_PROMPTS_BROWSER_SELF:-${BASH_SOURCE[0]}}"
  local header
  header=$'Tab=Fixed/Regex  Enter=粘贴  Esc=退出'

  while true; do
    local q
    q="$(state_read left_query "")"

    local selected
    selected="$(
      bash "$self" left_list "" | fzf \
        --exit-0 \
        --disabled \
        --layout=reverse \
        --info=inline \
        --prompt="$(bash "$self" left_prompt)" \
        --header="$header" \
        --query="$q" \
        --bind "change:reload(bash \"$self\" left_list {q} || true)" \
        --bind "focus:execute-silent(bash \"$self\" left_focus {} || true)" \
        --bind "ctrl-r:reload(bash \"$self\" left_list {q} || true)" \
        --bind "tab:execute-silent(bash \"$self\" left_toggle_mode)+transform-prompt(bash \"$self\" left_prompt)+reload(bash \"$self\" left_list {q} || true)"
    )" || true

    if [[ -z "${selected:-}" ]]; then
      close_popup
      exit 0
    fi

    set +e
    bash "$self" paste_file "$selected"
    rc=$?
    set -e

    if ((rc == 0)); then
      close_popup
      exit 0
    fi
    if ((rc == 2)); then
      continue
    fi

    pause
    close_popup
    exit 0
  done
}

right_pane() {
  state_dir_required

  local self="${CODEX_PROMPTS_BROWSER_SELF:-${BASH_SOURCE[0]}}"
  local header
  header=$'输入开始在左侧 scope 内全文检索（±5 行卡片）\nEnter=进入文件预览  Esc=清空/解除锁定  Tab=Fixed/Regex  C-r=刷新'

  bash "$self" right_list "" | fzf \
    --read0 \
    --exit-0 \
    --disabled \
    --ansi \
    --no-sort \
    --gap 1 \
    --layout=reverse \
    --info=inline \
    --prompt="$(bash "$self" right_prompt)" \
    --header="$header" \
    --bind "change:reload(bash \"$self\" right_list {q} || true)" \
    --bind "ctrl-r:reload(bash \"$self\" right_list {q} || true)" \
    --bind "enter:execute-silent(bash \"$self\" right_enter {})+clear-query+reload(bash \"$self\" right_list {q} || true)" \
    --bind "esc:execute-silent(bash \"$self\" right_clear_lock)+clear-query+reload(bash \"$self\" right_list {q} || true)" \
    --bind "tab:execute-silent(bash \"$self\" right_toggle_mode)+transform-prompt(bash \"$self\" right_prompt)+reload(bash \"$self\" right_list {q} || true)" \
    >/dev/null || true

  close_popup
  exit 0
}

popup_ui() {
  local origin_pane_id="${ORIGIN_PANE_ID:-${1:-}}"
  if [[ -z "${origin_pane_id:-}" ]]; then
    die "缺少 ORIGIN_PANE_ID（需要从 tmux bind-key 里传入触发 pane_id）。"
  fi

  if ! require_cmd fzf; then
    die "fzf 未安装：本功能依赖 fzf。"
  fi
  if ! require_cmd rg; then
    die "rg 未安装：本功能依赖 ripgrep（rg）。"
  fi
  if ! require_cmd python3; then
    die "python3 未安装：本功能依赖 python3。"
  fi

  local prompts_dir="${CODEX_PROMPTS_DIR:-${TMUX_CODEX_PROMPTS_DIR:-$HOME/.codex/prompts}}"
  if [[ ! -d "$prompts_dir" ]]; then
    die "目录不存在：$prompts_dir"
  fi

  local self
  self="${BASH_SOURCE[0]}"
  if require_cmd realpath; then
    self="$(realpath "$self")"
  fi

  local nested_server="codex_prompts_${USER}_$$"
  local nested_session="popup"
  local state_dir="${TMPDIR:-/tmp}/tmux_codex_prompts_${USER}_${nested_server}"

  mkdir -p "$state_dir" 2>/dev/null || true
  [[ -d "$state_dir" ]] || die "无法创建 state_dir：$state_dir"

  cleanup() {
    rm -rf "$state_dir" 2>/dev/null || true
    command tmux -L "$nested_server" kill-server >/dev/null 2>&1 || true
  }
  trap cleanup EXIT SIGINT SIGTERM SIGHUP

  export STATE_DIR="$state_dir"
  export NESTED_SERVER="$nested_server"
  export CODEX_PROMPTS_BROWSER_SELF="$self"
  export CODEX_PROMPTS_DIR="$prompts_dir"
  export ORIGIN_PANE_ID="$origin_pane_id"

  list_md_files "$prompts_dir" | sort -u >"$state_dir/all_files"
  if [[ ! -s "$state_dir/all_files" ]]; then
    die "未发现任何 .md：$prompts_dir"
  fi

  cp "$state_dir/all_files" "$state_dir/left_current_files"
  state_write left_mode fixed
  state_write right_mode fixed
  state_write left_query ""
  state_write right_query ""

  local first_file
  first_file="$(head -n 1 "$state_dir/all_files" 2>/dev/null || true)"
  if [[ -n "${first_file:-}" ]]; then
    state_write left_selected_file "$first_file"
  fi

  command tmux -L "$nested_server" -f /dev/null new-session -d -s "$nested_session" -n codex-prompts >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g status off >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g mouse on >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g focus-events on >/dev/null 2>&1 || true

  command tmux -L "$nested_server" setw -g pane-border-status top >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g pane-border-format ' #{pane_title} ' >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g pane-border-style fg=colour238 >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g pane-active-border-style fg=colour45 >/dev/null 2>&1 || true

  # Layout: left (files) | right (preview/search)
  command tmux -L "$nested_server" split-window -h -p 55 -t "$nested_session:0.0" -d >/dev/null 2>&1 || true

  local left_pane right_pane
  left_pane="$(command tmux -L "$nested_server" display-message -p -t "$nested_session:0.0" '#{pane_id}' 2>/dev/null || true)"
  right_pane="$(command tmux -L "$nested_server" display-message -p -t "$nested_session:0.1" '#{pane_id}' 2>/dev/null || true)"

  command tmux -L "$nested_server" select-pane -t "$left_pane" -T "FILES" >/dev/null 2>&1 || true
  command tmux -L "$nested_server" select-pane -t "$right_pane" -T "RIGHT" >/dev/null 2>&1 || true

  export RIGHT_PANE_ID="$right_pane"

  command tmux -L "$nested_server" respawn-pane -k -t "$right_pane" \
    "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' CODEX_PROMPTS_BROWSER_SELF='$self' CODEX_PROMPTS_DIR='$prompts_dir' ORIGIN_PANE_ID='$origin_pane_id' OUTER_TMUX_SOCKET='$(outer_socket_detect)' bash '$self' right_pane" \
    >/dev/null 2>&1 || true

  command tmux -L "$nested_server" respawn-pane -k -t "$left_pane" \
    "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' CODEX_PROMPTS_BROWSER_SELF='$self' CODEX_PROMPTS_DIR='$prompts_dir' ORIGIN_PANE_ID='$origin_pane_id' RIGHT_PANE_ID='$right_pane' OUTER_TMUX_SOCKET='$(outer_socket_detect)' bash '$self' left_pane" \
    >/dev/null 2>&1 || true

  command tmux -L "$nested_server" -f /dev/null attach-session -t "$nested_session" >/dev/null 2>&1 || true
}

cmd="${1:-popup_ui}"
shift || true
case "$cmd" in
  popup_ui) popup_ui "$@" ;;
  left_pane) left_pane "$@" ;;
  right_pane) right_pane "$@" ;;
  left_list) left_list "$@" ;;
  left_toggle_mode) left_toggle_mode "$@" ;;
  left_prompt) left_prompt "$@" ;;
  left_focus) left_focus "$@" ;;
  right_list) right_list "$@" ;;
  right_toggle_mode) right_toggle_mode "$@" ;;
  right_prompt) right_prompt "$@" ;;
  right_enter) right_enter "$@" ;;
  right_clear_lock) right_clear_lock "$@" ;;
  paste_file) paste_file "$@" ;;
  close_popup) close_popup "$@" ;;
  *) popup_ui "$cmd" "$@" ;;
esac
