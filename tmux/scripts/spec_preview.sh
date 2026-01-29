#!/usr/bin/env bash
# desc: Spec 预览：三列联动（spec → US → task）+ 文件浏览（fzf + bat），可用 nvim 打开并定位
# usage: spec_preview.sh [编号]  # 例：spec_preview.sh 70 / 070；不传则先选 spec
#       spec_preview.sh --spec-path <path>  # 直接进入某个 specs/<NNN-*> 目录
#       spec_preview.sh --repo-root <path>  # 指定目标仓库根目录（需包含 specs/）
#       spec_preview.sh --mode board|files  # board=三列联动；files=目录内文件浏览
# keys:
#   board: 三列联动；Enter 打开并定位（zz 居中）；C-r 刷新；C-a C-a 关闭 popup（外层 tmux）
#   files: enter: nvim 打开并退出 | ctrl-e: nvim 打开但不退出 | ctrl-/: 预览开关 | esc: 返回/退出
set -euo pipefail

pause() {
  local prompt="${1:-按任意键关闭...}"
  if [[ -t 1 ]]; then
    if [[ -r /dev/tty ]]; then
      read -r -n 1 -s -p "$prompt" < /dev/tty || true
    else
      read -r -n 1 -s -p "$prompt" || true
    fi
    printf '\n'
  fi
}

die() {
  printf '%s\n' "$1"
  pause
  exit 0
}

print_help() {
  cat <<'EOF'
用法: spec_preview.sh [编号]
  例: spec_preview.sh 70
      spec_preview.sh 070
      spec_preview.sh --spec-path /abs/path/to/specs/070-xxx
      spec_preview.sh --repo-root /abs/path/to/repo
      spec_preview.sh --mode board
说明:
  - 若提供编号：优先匹配 specs/<NNN-*> 目录
  - 若提供 --spec-path：直接进入该 spec 目录浏览文件
  - 若不提供：先用 fzf 选择一个 specs/<NNN-*> 目录，再浏览其中的文件
EOF
}

need_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '%s\n' "缺少依赖：$cmd${hint:+（$hint）}"
    pause
    exit 0
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

nvim_open_at_line_center() {
  local file="$1"
  local line="${2:-1}"
  if ! require_cmd nvim; then
    printf '%s\n' "未检测到 nvim：无法打开文件。"
    pause
    return 0
  fi
  if [[ ! "$line" =~ ^[0-9]+$ ]] || ((line <= 0)); then
    line="1"
  fi
  # 兼容用户配置里“打开文件回到上次光标”的 autocmd：用 VimEnter 再强制跳一次，确保最终落点正确。
  nvim +"call cursor(${line}, 1)" +"normal! zz" -c "autocmd VimEnter * ++once call cursor(${line}, 1) | normal! zz" -- "$file" < /dev/tty > /dev/tty
}

find_repo_paths() {
  local start_dir="${1:-$PWD}"
  local override_root="${2:-}"

  local env_root="${SPEC_PREVIEW_REPO_ROOT:-${SPECKIT_REPO_ROOT:-${SPECKIT_KIT_REPO_ROOT:-}}}"

  if [[ -n "${override_root:-}" ]]; then
    env_root="$override_root"
  fi

  if [[ -n "${env_root:-}" ]]; then
    local repo_root
    repo_root="$(cd "$env_root" 2>/dev/null && pwd)" || return 1
    local specs_root="$repo_root/specs"
    if [[ -d "$specs_root" ]]; then
      printf '%s\t%s\n' "$repo_root" "$specs_root"
      return 0
    fi
    return 1
  fi

  local dir
  dir="$(cd "$start_dir" 2>/dev/null && pwd)" || dir="$start_dir"

  while true; do
    if [[ -d "$dir/specs" ]]; then
      printf '%s\t%s\n' "$dir" "$dir/specs"
      return 0
    fi
    local parent
    parent="$(dirname "$dir")"
    if [[ "$parent" == "$dir" ]]; then
      break
    fi
    dir="$parent"
  done

  return 1
}

infer_title_from_spec_md() {
  local file="$1"
  local fallback="$2"
  if [[ ! -f "$file" ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  local title
  title="$(awk '/^# / { sub(/^# /, "", $0); print; exit }' "$file" 2>/dev/null || true)"
  title="${title#"${title%%[![:space:]]*}"}"
  title="${title%"${title##*[![:space:]]}"}"
  printf '%s' "${title:-$fallback}"
}

count_tasks_done_total() {
  local tasks_file="$1"
  if [[ ! -f "$tasks_file" ]]; then
    printf '0\t0\n'
    return 0
  fi
  awk '
    BEGIN { total = 0; done = 0 }
    {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]+/) {
        total++
        if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]+/) done++
      }
    }
    END { printf "%d\t%d\n", done, total }
  ' "$tasks_file" 2>/dev/null || printf '0\t0\n'
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

board_list_specs() {
  state_dir_required
  local specs_dir
  specs_dir="$(state_read specs_dir "")"
  if [[ -z "${specs_dir:-}" || ! -d "$specs_dir" ]]; then
    exit 0
  fi

  shopt -s nullglob
  for spec_dir in "$specs_dir"/[0-9][0-9][0-9]-*; do
    [[ -d "$spec_dir" ]] || continue
    local spec_id num
    spec_id="$(basename "$spec_dir")"
    num="${spec_id%%-*}"
    [[ "$num" =~ ^[0-9]{3}$ ]] || continue

    local done total title
    read -r done total < <(count_tasks_done_total "$spec_dir/tasks.md" | tr '\t' ' ')
    title="$(infer_title_from_spec_md "$spec_dir/spec.md" "$spec_id")"

    printf '%s\t%s\t%d/%d\t%s\n' "$num" "$spec_id" "$done" "$total" "$title"
  done | sort -r -n -k1,1
}

board_list_us() {
  state_dir_required
  local specs_dir spec_id
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  if [[ -z "${specs_dir:-}" || -z "${spec_id:-}" ]]; then
    exit 0
  fi

  local spec_dir spec_md tasks_md
  spec_dir="$specs_dir/$spec_id"
  spec_md="$spec_dir/spec.md"
  tasks_md="$spec_dir/tasks.md"

  [[ -f "$spec_md" ]] || spec_md="/dev/null"
  [[ -f "$tasks_md" ]] || tasks_md="/dev/null"

  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    function parse_us_heading(text,    m, idx, rest, title, code) {
      if (text !~ /^User[[:space:]]+Story[[:space:]]+[0-9]+/) return 0

      rest = text
      sub(/^User[[:space:]]+Story[[:space:]]+/, "", rest)

      idx = rest
      sub(/[^0-9].*$/, "", idx)
      idx = idx + 0

      sub(/^[0-9]+/, "", rest)
      rest = trim(rest)
      sub(/\(\s*Priority\s*:\s*P[0-9]+\s*\)\s*$/, "", rest)
      rest = trim(rest)
      sub(/^[-–—:：][[:space:]]*/, "", rest)
      rest = trim(rest)
      title = rest != "" ? rest : ("User Story " idx)
      code = "US" idx
      us_title[code] = title
      us_line[code] = NR
      us_index[code] = idx
      codes[code] = 1
      return 1
    }

    function parse_story_from_title(title,    m) {
      if (match(title, /\[US[0-9]+\]/)) return substr(title, RSTART + 1, RLENGTH - 2)
      return ""
    }

    function parse_task(line,    m, checked, title, story) {
      if (!match(line, /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]+/)) return 0
      checked = match(line, /^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]+/) ? 1 : 0
      title = line
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]+/, "", title)
      story = parse_story_from_title(title)

      total_all++
      if (checked) done_all++

      if (story != "") {
        t_total[story]++
        if (checked) t_done[story]++
        codes[story] = 1
      } else {
        no_us_total++
        if (checked) no_us_done++
      }
      return 1
    }

    FNR == NR {
      if (match($0, /^#{1,6}[[:space:]]+/)) {
        heading = $0
        sub(/^#{1,6}[[:space:]]+/, "", heading)
        heading = trim(heading)
        parse_us_heading(heading)
      }
      next
    }

    {
      parse_task($0)
    }

    END {
      # ALL
      printf "%d\t%s\t%d/%d\t%s\t%d\n", 0, "ALL", done_all + 0, total_all + 0, "全部", 0

      for (c in codes) {
        if (c == "ALL") continue
        idx = (c in us_index) ? us_index[c] : 0
        # story codes always look like USn
        if (idx == 0 && match(c, /^US[0-9]+$/)) idx = substr(c, 3) + 0
        title = (c in us_title) ? us_title[c] : c
        line = (c in us_line) ? us_line[c] : 0
        done = (c in t_done) ? t_done[c] : 0
        total = (c in t_total) ? t_total[c] : 0
        printf "%d\t%s\t%d/%d\t%s\t%d\n", idx, c, done, total, title, line
      }

      # NO_US
      printf "%d\t%s\t%d/%d\t%s\t%d\n", 999999, "NO_US", no_us_done + 0, no_us_total + 0, "(no US)", 0
    }
  ' "$spec_md" "$tasks_md" | sort -n -k1,1
}

board_list_tasks() {
  state_dir_required
  local specs_dir spec_id us_code
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  us_code="$(state_read selected_us_code "ALL")"
  if [[ -z "${specs_dir:-}" || -z "${spec_id:-}" ]]; then
    exit 0
  fi

  local tasks_md
  tasks_md="$specs_dir/$spec_id/tasks.md"
  if [[ ! -f "$tasks_md" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "—" " " "" "（无 tasks.md）" ""
    return 0
  fi

  awk -v US_CODE="$us_code" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    function collapse(s) {
      gsub(/[[:space:]][[:space:]]+/, " ", s)
      return s
    }

    function parse_story(title,    m) {
      if (match(title, /\[US[0-9]+\]/)) return substr(title, RSTART + 1, RLENGTH - 2)
      return ""
    }

    function parse_task_id(title,    m) {
      if (match(title, /T[0-9][0-9][0-9]/)) return substr(title, RSTART, RLENGTH)
      return ""
    }

    function display_title(title, task_id, story,    out) {
      out = title

      if (task_id != "") {
        sub("^[[:space:]]*" task_id "\\b[[:space:]]*", "", out)
        sub(/^[[:space:]]*[-–—·:：][[:space:]]*/, "", out)
      }

      if (story != "") {
        gsub("\\[" story "\\]", " ", out)
      }

      gsub(/\[P\]/, " ", out)

      out = trim(collapse(out))
      return out != "" ? out : title
    }

    BEGIN { found = 0 }

    {
      if (!match($0, /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]+/)) next

      checked = match($0, /^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]+/) ? "x" : " "
      title = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]+/, "", title)
      story = parse_story(title)
      task_id = parse_task_id(title)

      if (US_CODE == "ALL") {
        # keep
      } else if (US_CODE == "NO_US") {
        if (story != "") next
      } else {
        if (story != US_CODE) next
      }

      line_no = NR
      disp = display_title(title, task_id, story)
      printf "%d\t%s\t%s\t%s\t%s\n", line_no, checked, task_id, disp, $0
      found = 1
    }

    END {
      if (found == 0) {
        printf "—\t \t\t（未发现 task：tasks.md 里没有 - [ ] 行）\t\n"
      }
    }
  ' "$tasks_md"
}

board_spec_focus() {
  state_dir_required
  local spec_id="${1:-}"
  [[ -n "${spec_id:-}" ]] || return 0

  local prev
  prev="$(state_read selected_spec_id "")"
  if [[ "$spec_id" == "$prev" ]]; then
    return 0
  fi

  state_write selected_spec_id "$spec_id"
  state_write selected_us_code "ALL"
  state_write selected_task_line ""
  state_write selected_artifact_relpath ""

  local us_pane task_pane
  us_pane="$(state_read us_pane_id "")"
  task_pane="$(state_read task_pane_id "")"

  local view_mode
  view_mode="$(state_read view_mode "board")"

  if [[ "$view_mode" == "artifacts" ]]; then
    board_try_close_editor "artifact" "$us_pane" || true
    artifacts_signal_preview_refresh || true
    if [[ -n "${us_pane:-}" ]]; then
      if [[ "$(state_read artifact_editor_open "0")" != "1" ]]; then
        tmux_nested send-keys -t "$us_pane" C-r >/dev/null 2>&1 || true
      fi
    fi
    return 0
  fi

  board_try_close_editor "us" "$us_pane" || true
  board_try_close_editor "task" "$task_pane" || true
  board_signal_task_preview_refresh || true

  if [[ -n "${us_pane:-}" ]]; then
    if [[ "$(state_read us_editor_open "0")" != "1" ]]; then
      tmux_nested send-keys -t "$us_pane" C-r >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${task_pane:-}" ]]; then
    if [[ "$(state_read task_editor_open "0")" != "1" ]]; then
      tmux_nested send-keys -t "$task_pane" C-r >/dev/null 2>&1 || true
    fi
  fi
}

board_us_focus() {
  state_dir_required
  local us_code="${1:-}"
  [[ -n "${us_code:-}" ]] || return 0

  local prev
  prev="$(state_read selected_us_code "ALL")"
  if [[ "$us_code" == "$prev" ]]; then
    return 0
  fi

  state_write selected_us_code "$us_code"
  state_write selected_task_line ""

  local task_pane
  task_pane="$(state_read task_pane_id "")"

  board_try_close_editor "task" "$task_pane" || true
  board_signal_task_preview_refresh || true
  if [[ -n "${task_pane:-}" ]]; then
    if [[ "$(state_read task_editor_open "0")" != "1" ]]; then
      tmux_nested send-keys -t "$task_pane" C-r >/dev/null 2>&1 || true
    fi
  fi
}

board_task_focus() {
  state_dir_required
  local line="${1:-}"
  [[ -n "${line:-}" ]] || return 0
  [[ "$line" =~ ^[0-9]+$ ]] || return 0

  local prev
  prev="$(state_read selected_task_line "")"
  if [[ "$line" == "$prev" ]]; then
    return 0
  fi

  state_write selected_task_line "$line"
  board_signal_task_preview_refresh
}

board_signal_task_preview_refresh() {
  state_dir_required
  tmux_nested wait-for -S speckit_spec_preview_task_refresh >/dev/null 2>&1 || true
}

artifacts_signal_preview_refresh() {
  state_dir_required
  tmux_nested wait-for -S speckit_spec_preview_artifact_refresh >/dev/null 2>&1 || true
}

board_close_popup() {
  state_dir_required
  state_write closing "1"
  tmux_nested kill-server >/dev/null 2>&1 || true
}

board_try_close_editor() {
  state_dir_required
  local kind="${1:-}"
  local pane_id="${2:-}"
  if [[ -z "${kind:-}" || -z "${pane_id:-}" ]]; then
    return 0
  fi

  local flag_key
  flag_key="${kind}_editor_open"

  if [[ "$(state_read "$flag_key" "0")" != "1" ]]; then
    return 0
  fi

  # Best-effort: ask nvim to save-if-changed then quit, so the list can resume syncing.
  tmux_nested send-keys -t "$pane_id" Escape Escape >/dev/null 2>&1 || true
  tmux_nested send-keys -t "$pane_id" -l ":update | q" >/dev/null 2>&1 || true
  tmux_nested send-keys -t "$pane_id" Enter >/dev/null 2>&1 || true

  # Wait briefly for the editor to exit (flag cleared by the execute() wrapper).
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [[ "$(state_read "$flag_key" "0")" != "1" ]]; then
      return 0
    fi
    sleep 0.05
  done

  return 1
}

board_focus_pane() {
  state_dir_required
  local target="${1:-}"
  local pane_id=""

  case "$target" in
    spec) pane_id="$(state_read spec_pane_id "")" ;;
    us) pane_id="$(state_read us_pane_id "")" ;;
    task) pane_id="$(state_read task_pane_id "")" ;;
    *) return 0 ;;
  esac

  if [[ -n "${pane_id:-}" ]]; then
    tmux_nested select-pane -t "$pane_id" >/dev/null 2>&1 || true
  fi
}

ui_switch_to_artifacts() {
  state_dir_required

  local self="${SPEC_PREVIEW_SELF:-${BASH_SOURCE[0]}}"
  local state_dir="${STATE_DIR:-}"
  local nested_server="${NESTED_SERVER:-}"
  local invoker_pane="${TMUX_PANE:-}"

  local spec_pane us_pane task_pane preview_pane
  spec_pane="$(state_read spec_pane_id "")"
  us_pane="$(state_read us_pane_id "")"
  task_pane="$(state_read task_pane_id "")"
  preview_pane="$(state_read task_preview_pane_id "")"

  state_write view_mode "artifacts"
  state_write selected_artifact_relpath ""

  if [[ -n "${preview_pane:-}" ]]; then
    tmux_nested kill-pane -t "$preview_pane" >/dev/null 2>&1 || true
  fi
  state_write task_preview_pane_id ""

  [[ -n "${spec_pane:-}" ]] && tmux_nested select-pane -t "$spec_pane" -T "SPEC" >/dev/null 2>&1 || true
  [[ -n "${us_pane:-}" ]] && tmux_nested select-pane -t "$us_pane" -T "FILES" >/dev/null 2>&1 || true
  [[ -n "${task_pane:-}" ]] && tmux_nested select-pane -t "$task_pane" -T "PREVIEW" >/dev/null 2>&1 || true

  # 关键：tab 触发切换时，这个函数通常由 fzf 的 execute-silent 启动；
  # 若先 respawn “当前 pane”，会把本进程一并 kill 掉，导致切换只做了一半（例如第三列残留旧预览）。
  # 这里把 invoker_pane 放到最后 respawn。
  local first_pane second_pane
  first_pane="$us_pane"
  second_pane="$task_pane"
  if [[ -n "${invoker_pane:-}" && "$invoker_pane" == "$us_pane" ]]; then
    first_pane="$task_pane"
    second_pane="$us_pane"
  elif [[ -n "${invoker_pane:-}" && "$invoker_pane" == "$task_pane" ]]; then
    first_pane="$us_pane"
    second_pane="$task_pane"
    [[ -n "${us_pane:-}" ]] && tmux_nested select-pane -t "$us_pane" >/dev/null 2>&1 || true
  else
    [[ -n "${us_pane:-}" ]] && tmux_nested select-pane -t "$us_pane" >/dev/null 2>&1 || true
  fi

  if [[ -n "${first_pane:-}" && "$first_pane" == "$us_pane" ]]; then
    tmux_nested respawn-pane -k -t "$us_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __artifact_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${first_pane:-}" && "$first_pane" == "$task_pane" ]]; then
    tmux_nested respawn-pane -k -t "$task_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __artifact_preview_pane" \
      >/dev/null 2>&1 || true
  fi

  artifacts_signal_preview_refresh || true

  if [[ -n "${second_pane:-}" && "$second_pane" == "$us_pane" ]]; then
    tmux_nested respawn-pane -k -t "$us_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __artifact_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${second_pane:-}" && "$second_pane" == "$task_pane" ]]; then
    tmux_nested respawn-pane -k -t "$task_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __artifact_preview_pane" \
      >/dev/null 2>&1 || true
  fi
}

ui_switch_to_board() {
  state_dir_required

  local self="${SPEC_PREVIEW_SELF:-${BASH_SOURCE[0]}}"
  local state_dir="${STATE_DIR:-}"
  local nested_server="${NESTED_SERVER:-}"
  local invoker_pane="${TMUX_PANE:-}"

  local spec_pane us_pane task_pane preview_pane
  spec_pane="$(state_read spec_pane_id "")"
  us_pane="$(state_read us_pane_id "")"
  task_pane="$(state_read task_pane_id "")"
  preview_pane="$(state_read task_preview_pane_id "")"

  state_write view_mode "board"

  if [[ -z "${preview_pane:-}" && -n "${task_pane:-}" ]]; then
    preview_pane="$(
      tmux_nested split-window -v -p 45 -t "$task_pane" -d -P -F '#{pane_id}' 2>/dev/null || true
    )"
    state_write task_preview_pane_id "$preview_pane"
  fi

  [[ -n "${spec_pane:-}" ]] && tmux_nested select-pane -t "$spec_pane" -T "SPEC" >/dev/null 2>&1 || true
  [[ -n "${us_pane:-}" ]] && tmux_nested select-pane -t "$us_pane" -T "US" >/dev/null 2>&1 || true
  [[ -n "${task_pane:-}" ]] && tmux_nested select-pane -t "$task_pane" -T "TASK" >/dev/null 2>&1 || true
  [[ -n "${preview_pane:-}" ]] && tmux_nested select-pane -t "$preview_pane" -T "PREVIEW" >/dev/null 2>&1 || true

  # 同上：避免 respawn 当前 pane 让切换进程中途被 kill，导致 panes 只切了一半。
  local first_pane second_pane third_pane
  first_pane="$us_pane"
  second_pane="$task_pane"
  third_pane="$preview_pane"

  # 把 invoker 放到最后一个非空位置（最多 3 个）。
  if [[ -n "${invoker_pane:-}" ]]; then
    if [[ "$invoker_pane" == "$us_pane" ]]; then
      first_pane="$task_pane"
      second_pane="$preview_pane"
      third_pane="$us_pane"
    elif [[ "$invoker_pane" == "$task_pane" ]]; then
      first_pane="$us_pane"
      second_pane="$preview_pane"
      third_pane="$task_pane"
    elif [[ -n "${preview_pane:-}" && "$invoker_pane" == "$preview_pane" ]]; then
      first_pane="$us_pane"
      second_pane="$task_pane"
      third_pane="$preview_pane"
    fi
  fi

  if [[ -n "${first_pane:-}" && "$first_pane" == "$us_pane" ]]; then
    tmux_nested respawn-pane -k -t "$us_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __us_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${first_pane:-}" && "$first_pane" == "$task_pane" ]]; then
    tmux_nested respawn-pane -k -t "$task_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${first_pane:-}" && -n "${preview_pane:-}" && "$first_pane" == "$preview_pane" ]]; then
    tmux_nested respawn-pane -k -t "$preview_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_preview_pane" \
      >/dev/null 2>&1 || true
  fi

  if [[ -n "${second_pane:-}" && "$second_pane" == "$us_pane" ]]; then
    tmux_nested respawn-pane -k -t "$us_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __us_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${second_pane:-}" && "$second_pane" == "$task_pane" ]]; then
    tmux_nested respawn-pane -k -t "$task_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${second_pane:-}" && -n "${preview_pane:-}" && "$second_pane" == "$preview_pane" ]]; then
    tmux_nested respawn-pane -k -t "$preview_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_preview_pane" \
      >/dev/null 2>&1 || true
  fi

  board_signal_task_preview_refresh || true
  [[ -n "${task_pane:-}" ]] && tmux_nested select-pane -t "$task_pane" >/dev/null 2>&1 || true

  if [[ -n "${third_pane:-}" && "$third_pane" == "$us_pane" ]]; then
    tmux_nested respawn-pane -k -t "$us_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __us_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${third_pane:-}" && "$third_pane" == "$task_pane" ]]; then
    tmux_nested respawn-pane -k -t "$task_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_pane" \
      >/dev/null 2>&1 || true
  elif [[ -n "${third_pane:-}" && -n "${preview_pane:-}" && "$third_pane" == "$preview_pane" ]]; then
    tmux_nested respawn-pane -k -t "$preview_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_preview_pane" \
      >/dev/null 2>&1 || true
  fi
}

ui_toggle_view() {
  state_dir_required
  local view_mode
  view_mode="$(state_read view_mode "board")"
  if [[ "$view_mode" == "artifacts" ]]; then
    ui_switch_to_board
  else
    ui_switch_to_artifacts
  fi
}

board_render_task_preview() {
  state_dir_required

  local specs_dir spec_id tasks_file line
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  line="$(state_read selected_task_line "")"

  if [[ -z "${specs_dir:-}" || -z "${spec_id:-}" ]]; then
    printf '%s\n' "未选择 spec。"
    return 0
  fi

  tasks_file="$specs_dir/$spec_id/tasks.md"

  if [[ ! -f "$tasks_file" ]]; then
    printf '%s\n' "tasks.md 不存在：$tasks_file"
    return 0
  fi
  if [[ -z "${line:-}" || ! "$line" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "在上方选择一个 task 以预览。"
    return 0
  fi

  local pane_height pane_width
  if [[ -n "${TMUX_PANE:-}" ]]; then
    pane_height="$(tmux_nested display-message -p -t "$TMUX_PANE" '#{pane_height}' 2>/dev/null || true)"
    pane_width="$(tmux_nested display-message -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null || true)"
  else
    pane_height="$(tmux_nested display-message -p '#{pane_height}' 2>/dev/null || true)"
    pane_width="$(tmux_nested display-message -p '#{pane_width}' 2>/dev/null || true)"
  fi
  if [[ -z "${pane_height:-}" || ! "$pane_height" =~ ^[0-9]+$ ]]; then
    pane_height="30"
  fi
  if [[ -z "${pane_width:-}" || ! "$pane_width" =~ ^[0-9]+$ ]]; then
    pane_width="120"
  fi

  # Python 渲染器：保证“高亮行居中 + 满屏输出 + 无滚屏 + 不受 bat 的 TTY 检测影响”。
  python3 - "$tasks_file" "$line" "$pane_width" "$pane_height" <<'PY'
import sys
import unicodedata

path = sys.argv[1]
highlight = int(sys.argv[2])
pane_width = int(sys.argv[3])
pane_height = int(sys.argv[4])

if pane_width < 20:
  pane_width = 20
if pane_height < 5:
  pane_height = 5

try:
  with open(path, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
except Exception:
  lines = []

total = len(lines)
if total <= 0:
  sys.stdout.write('\n'.join([' ' * pane_width for _ in range(pane_height)]))
  raise SystemExit(0)

if highlight < 1:
  highlight = 1
if highlight > total:
  highlight = total

num_w = max(3, len(str(total)))
prefix_w = num_w + 1
content_w = pane_width - prefix_w
if content_w < 10:
  content_w = 10

def char_width(ch: str) -> int:
  if not ch:
    return 0
  if unicodedata.combining(ch):
    return 0
  eaw = unicodedata.east_asian_width(ch)
  return 2 if eaw in ('W', 'F') else 1

def string_width(s: str) -> int:
  w = 0
  for ch in s:
    cw = char_width(ch)
    w += cw
  return w

def pad_to_width(s: str, target_w: int) -> str:
  w = string_width(s)
  if w >= target_w:
    return s
  return s + (' ' * (target_w - w))

def wrap_segments(text: str, max_w: int) -> list[str]:
  if max_w <= 0:
    return [""]
  out: list[str] = []
  buf: list[str] = []
  w = 0
  for ch in text:
    cw = char_width(ch)
    if cw > max_w:
      continue
    if w + cw > max_w and buf:
      out.append("".join(buf))
      buf = []
      w = 0
    buf.append(ch)
    w += cw
  out.append("".join(buf))
  if not out:
    out = [""]
  return out

RESET = '\x1b[0m'
HILITE = '\x1b[7m'  # reverse video

def render_file_line(file_idx: int, is_highlight: bool) -> list[str]:
  if file_idx < 1 or file_idx > total:
    return [' ' * pane_width]
  raw = lines[file_idx - 1].rstrip('\n').expandtabs(2)
  segments = wrap_segments(raw, content_w)
  rows: list[str] = []
  for i, seg in enumerate(segments):
    if i == 0:
      prefix = f'{file_idx:>{num_w}} '
    else:
      prefix = ' ' * prefix_w
    row = prefix + seg
    row = pad_to_width(row, prefix_w + content_w)
    # 若 content_w 比 pane_width 小，补到 pane_width（理论上不会发生，但保持健壮）。
    row = pad_to_width(row, pane_width)
    if is_highlight:
      row = f'{HILITE}{row}{RESET}'
    rows.append(row)
  return rows

highlight_rows = render_file_line(highlight, True)
block_len = len(highlight_rows)
mid_idx = (pane_height - 1) // 2
block_center_idx = (block_len - 1) // 2

if block_len >= pane_height:
  start_idx = block_center_idx - mid_idx
  if start_idx < 0:
    start_idx = 0
  if start_idx + pane_height > block_len:
    start_idx = max(0, block_len - pane_height)
  sys.stdout.write('\n'.join(highlight_rows[start_idx:start_idx + pane_height]))
  raise SystemExit(0)

before_needed = mid_idx - block_center_idx
after_needed = pane_height - (before_needed + block_len)

before_rows: list[str] = []
line_no = highlight - 1
while len(before_rows) < before_needed:
  if line_no >= 1:
    rows = render_file_line(line_no, False)
    before_rows = rows + before_rows
    if len(before_rows) > before_needed:
      before_rows = before_rows[-before_needed:]
    line_no -= 1
  else:
    before_rows = ([' ' * pane_width] * (before_needed - len(before_rows))) + before_rows
    break

after_rows: list[str] = []
line_no = highlight + 1
while len(after_rows) < after_needed:
  if line_no <= total:
    rows = render_file_line(line_no, False)
    after_rows.extend(rows)
    if len(after_rows) > after_needed:
      after_rows = after_rows[:after_needed]
    line_no += 1
  else:
    after_rows.extend([' ' * pane_width] * (after_needed - len(after_rows)))
    break

out_lines = before_rows + highlight_rows + after_rows
if len(out_lines) < pane_height:
  out_lines.extend([' ' * pane_width] * (pane_height - len(out_lines)))
elif len(out_lines) > pane_height:
  out_lines = out_lines[:pane_height]

sys.stdout.write('\n'.join(out_lines))
PY
}

board_task_preview_pane() {
  state_dir_required

  while true; do
    # 更可靠的清屏：避免 clear 在某些 TERM 下不生效，导致旧内容“露出”。
    printf '\033[0m\033[2J\033[H' 2>/dev/null || true
    board_render_task_preview || true
    tmux_nested wait-for speckit_spec_preview_task_refresh >/dev/null 2>&1 || exit 0
  done
}

artifacts_list_files() {
  state_dir_required
  local specs_dir spec_id
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  if [[ -z "${specs_dir:-}" || -z "${spec_id:-}" ]]; then
    exit 0
  fi

  local spec_dir
  spec_dir="$specs_dir/$spec_id"
  [[ -d "$spec_dir" ]] || exit 0

  local rels=()
  while IFS= read -r rel; do
    [[ -n "${rel:-}" ]] || continue
    rels+=("$rel")
  done < <(
    cd "$spec_dir" 2>/dev/null || exit 0
    rg --files 2>/dev/null || true
  )

  if ((${#rels[@]} == 0)); then
    printf '%s\t%s\n' "99" "（无可预览产物）"
    return 0
  fi

  for rel in "${rels[@]}"; do
    local w="50"
    case "$rel" in
      spec.md) w="01" ;;
      plan.md) w="02" ;;
      tasks.md) w="03" ;;
      quickstart.md) w="04" ;;
      data-model.md) w="05" ;;
      research.md) w="06" ;;
      README.md) w="07" ;;
      handoff.md) w="08" ;;
      checklists/*) w="20" ;;
      contracts/*) w="30" ;;
      *.md) w="40" ;;
      *) w="60" ;;
    esac
    printf '%s\t%s\n' "$w" "$rel"
  done | sort -n -k1,1 -k2,2
}

artifacts_file_focus() {
  state_dir_required
  local rel="${1:-}"
  [[ -n "${rel:-}" ]] || return 0

  local prev
  prev="$(state_read selected_artifact_relpath "")"
  local specs_dir spec_id file
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  file="$specs_dir/$spec_id/$rel"
  if [[ -z "${specs_dir:-}" || -z "${spec_id:-}" || ! -f "$file" ]]; then
    if [[ -n "${prev:-}" ]]; then
      state_write selected_artifact_relpath ""
      artifacts_signal_preview_refresh
    fi
    return 0
  fi

  if [[ "$rel" == "$prev" ]]; then
    return 0
  fi

  state_write selected_artifact_relpath "$rel"
  artifacts_signal_preview_refresh
}

artifacts_open_file() {
  state_dir_required
  local rel="${1:-}"
  [[ -n "${rel:-}" ]] || return 0

  local specs_dir spec_id file
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  file="$specs_dir/$spec_id/$rel"
  [[ -f "$file" ]] || return 0

  state_write artifact_editor_open "1"
  nvim_open_at_line_center "$file" 1
  state_write artifact_editor_open "0"
  artifacts_signal_preview_refresh || true
}

artifacts_render_preview() {
  state_dir_required

  local specs_dir spec_id rel file
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  rel="$(state_read selected_artifact_relpath "")"

  if [[ -z "${specs_dir:-}" || -z "${spec_id:-}" ]]; then
    printf '%s\n' "未选择 spec。"
    return 0
  fi

  if [[ -z "${rel:-}" ]]; then
    printf '%s\n' "在中间选择一个产物以预览。"
    return 0
  fi

  file="$specs_dir/$spec_id/$rel"
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "文件不存在：$rel"
    return 0
  fi

  local pane_width max_lines
  if [[ -n "${TMUX_PANE:-}" ]]; then
    pane_width="$(tmux_nested display-message -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null || true)"
  else
    pane_width="$(tmux_nested display-message -p '#{pane_width}' 2>/dev/null || true)"
  fi
  if [[ -z "${pane_width:-}" || ! "$pane_width" =~ ^[0-9]+$ ]]; then
    pane_width="120"
  fi

  max_lines="${SPEC_PREVIEW_ARTIFACT_MAX_LINES:-400}"
  if [[ -z "${max_lines:-}" || ! "$max_lines" =~ ^[0-9]+$ ]]; then
    max_lines="400"
  fi

  printf '%s\n' "$rel"
  printf '%s\n' ""
  if require_cmd bat; then
    bat \
      --paging=never \
      --style=numbers \
      --wrap=character \
      --terminal-width "$pane_width" \
      --color=always \
      --line-range ":${max_lines}" \
      -- "$file"
  else
    sed -n "1,${max_lines}p" "$file"
  fi
}

artifacts_preview_pane() {
  state_dir_required

  while true; do
    # 产物预览希望“默认从顶部开始看”：
    # - 清掉该 pane 的 scrollback（避免 history-top 看到旧文件残留）
    # - 渲染后自动进入 copy-mode 并跳到顶，这样滚轮可直接向下滚
    tmux_nested send-keys -t "${TMUX_PANE:-}" -X cancel >/dev/null 2>&1 || true
    tmux_nested clear-history -t "${TMUX_PANE:-}" >/dev/null 2>&1 || true

    printf '\033[0m\033[2J\033[H' 2>/dev/null || true
    artifacts_render_preview || true

    tmux_nested copy-mode -e -t "${TMUX_PANE:-}" >/dev/null 2>&1 || true
    tmux_nested send-keys -t "${TMUX_PANE:-}" -X history-top >/dev/null 2>&1 || true

    tmux_nested wait-for speckit_spec_preview_artifact_refresh >/dev/null 2>&1 || exit 0
  done
}

artifacts_pane() {
  state_dir_required
  if ! require_cmd fzf; then
    die "fzf 未安装：本功能依赖 fzf。"
  fi

  local self="${SPEC_PREVIEW_SELF:-${BASH_SOURCE[0]}}"
  local header
  header=$'↑/↓ 选择产物（焦点联动 → 右侧预览）  ←/→ 切换列  Enter 打开（nvim）\nTab 切换视图（spec→US→task ↔ spec→产物→预览）  C-r 刷新'

  # Ensure preview shows something immediately if possible.
  local first_rel
  first_rel="$(bash "$self" __list_artifacts | head -n 1 | awk -F'\t' '{print $2}' 2>/dev/null || true)"
  if [[ -n "${first_rel:-}" ]]; then
    bash "$self" __artifact_focus "$first_rel" >/dev/null 2>&1 || true
  fi

  bash "$self" __list_artifacts | fzf \
    --exit-0 \
    --layout=reverse \
    --info=inline \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt='file> ' \
    --header="$header" \
    --bind "focus:execute-silent(bash \"$self\" __artifact_focus {2} || true)" \
    --bind "left:execute-silent(bash \"$self\" __focus_pane spec || true)+ignore" \
    --bind "right:execute-silent(bash \"$self\" __focus_pane task || true)+ignore" \
    --bind "tab:execute-silent(bash \"$self\" __toggle_view || true)+ignore" \
    --bind "ctrl-r:reload(bash \"$self\" __list_artifacts || true)+first+execute-silent(bash \"$self\" __artifact_focus {2} || true)" \
    --bind "enter:execute(bash \"$self\" __open_artifact {2} || true)" \
    --bind "esc:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    --bind "ctrl-c:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    >/dev/null || true

  bash "$self" __close_popup >/dev/null 2>&1 || true
}

board_open_spec_at_line() {
  state_dir_required
  local line="${1:-1}"
  local specs_dir spec_id file
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  file="$specs_dir/$spec_id/spec.md"
  [[ -f "$file" ]] || return 0
  state_write us_editor_open "1"
  nvim_open_at_line_center "$file" "$line"
  state_write us_editor_open "0"
}

board_open_task_at_line() {
  state_dir_required
  local line="${1:-1}"
  local specs_dir spec_id file
  specs_dir="$(state_read specs_dir "")"
  spec_id="$(state_read selected_spec_id "")"
  file="$specs_dir/$spec_id/tasks.md"
  [[ -f "$file" ]] || return 0
  state_write task_editor_open "1"
  nvim_open_at_line_center "$file" "$line"
  state_write task_editor_open "0"
  board_signal_task_preview_refresh || true
}

board_spec_pane() {
  state_dir_required
  if ! require_cmd fzf; then
    die "fzf 未安装：本功能依赖 fzf。"
  fi

  local self="${SPEC_PREVIEW_SELF:-${BASH_SOURCE[0]}}"
  local header
  header=$'↑/↓ 选择 spec（焦点联动）  → 切到第二列\nTab 切换视图（spec→US→task ↔ spec→产物→预览）  C-r 刷新  Esc 退出'

  bash "$self" __list_specs | fzf \
    --exit-0 \
    --layout=reverse \
    --info=inline \
    --delimiter=$'\t' \
    --with-nth=3,2,4 \
    --prompt='spec> ' \
    --header="$header" \
    --bind "focus:execute-silent(bash \"$self\" __spec_focus {2} || true)" \
    --bind "right:execute-silent(bash \"$self\" __focus_pane us || true)+ignore" \
    --bind "tab:execute-silent(bash \"$self\" __toggle_view || true)+ignore" \
    --bind "esc:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    --bind "ctrl-c:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    --bind "ctrl-r:reload(bash \"$self\" __list_specs || true)" \
    >/dev/null || true

  bash "$self" __close_popup >/dev/null 2>&1 || true
}

board_us_pane() {
  state_dir_required
  if ! require_cmd fzf; then
    die "fzf 未安装：本功能依赖 fzf。"
  fi

  local self="${SPEC_PREVIEW_SELF:-${BASH_SOURCE[0]}}"
  local header
  header=$'↑/↓ 选择 User Story（焦点联动）  ←/→ 切换列  Enter 打开 spec.md 并定位（zz 居中）\nTab 切换视图（spec→US→task ↔ spec→产物→预览）  C-r 刷新（spec 变化时会自动触发）'

  bash "$self" __list_us | fzf \
    --exit-0 \
    --layout=reverse \
    --info=inline \
    --delimiter=$'\t' \
    --with-nth=2,3,4 \
    --prompt='us> ' \
    --header="$header" \
    --bind "focus:execute-silent(bash \"$self\" __us_focus {2} || true)" \
    --bind "left:execute-silent(bash \"$self\" __focus_pane spec || true)+ignore" \
    --bind "right:execute-silent(bash \"$self\" __focus_pane task || true)+ignore" \
    --bind "tab:execute-silent(bash \"$self\" __toggle_view || true)+ignore" \
    --bind "ctrl-r:reload(bash \"$self\" __list_us || true)+first" \
    --bind "enter:execute(bash \"$self\" __open_spec {5} || true)" \
    --bind "esc:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    --bind "ctrl-c:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    >/dev/null || true

  bash "$self" __close_popup >/dev/null 2>&1 || true
}

board_task_pane() {
  state_dir_required
  if ! require_cmd fzf; then
    die "fzf 未安装：本功能依赖 fzf。"
  fi

  local self="${SPEC_PREVIEW_SELF:-${BASH_SOURCE[0]}}"
  local header
  header=$'↑/↓ 选择 task（焦点联动 → 下方预览）  ← 切到 US 列  Enter 打开 tasks.md 并定位（zz 居中）\nTab 切换视图（spec→US→task ↔ spec→产物→预览）  C-r 刷新（spec/us 变化时会自动触发）'

  # Ensure preview shows something immediately if possible.
  local first_line
  first_line="$(bash "$self" __list_tasks | head -n 1 | awk -F'\t' '{print $1}' 2>/dev/null || true)"
  if [[ -n "${first_line:-}" && "$first_line" =~ ^[0-9]+$ ]]; then
    bash "$self" __task_focus "$first_line" >/dev/null 2>&1 || true
  fi

  bash "$self" __list_tasks | fzf \
    --exit-0 \
    --layout=reverse \
    --info=inline \
    --delimiter=$'\t' \
    --with-nth=1,2,3,4 \
    --prompt='task> ' \
    --header="$header" \
    --bind "left:execute-silent(bash \"$self\" __focus_pane us || true)+ignore" \
    --bind "tab:execute-silent(bash \"$self\" __toggle_view || true)+ignore" \
    --bind "focus:execute-silent(bash \"$self\" __task_focus {1} || true)" \
    --bind "ctrl-r:reload(bash \"$self\" __list_tasks || true)+first+execute-silent(bash \"$self\" __task_focus {1} || true)" \
    --bind "enter:execute(bash \"$self\" __open_task {1} || true)" \
    --bind "esc:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    --bind "ctrl-c:execute-silent(bash \"$self\" __close_popup || true)+abort" \
    >/dev/null || true

  bash "$self" __close_popup >/dev/null 2>&1 || true
}

board_popup_ui() {
  if ! require_cmd tmux || [[ -z "${TMUX:-}" ]]; then
    die "board 模式需要在 tmux 内运行。"
  fi
  if ! require_cmd fzf; then
    die "fzf 未安装：本功能依赖 fzf。"
  fi

  local start_dir="${SPEC_PREVIEW_START_DIR:-$PWD}"
  local repo_root_override="${SPEC_PREVIEW_REPO_ROOT_OVERRIDE:-}"

  local resolved
  resolved="$(find_repo_paths "$start_dir" "$repo_root_override" 2>/dev/null || true)"
  if [[ -z "${resolved:-}" ]]; then
    die "找不到 specs/（可用 --repo-root 指定目标仓库根目录）。"
  fi

  local repo_root specs_dir
  repo_root="${resolved%%$'\t'*}"
  specs_dir="${resolved#*$'\t'}"

  shopt -s nullglob
  local spec_candidates=("$specs_dir"/[0-9][0-9][0-9]-*)
  if ((${#spec_candidates[@]} == 0)); then
    die "未发现任何 spec：$specs_dir/<NNN-*>"
  fi

  local self
  self="${BASH_SOURCE[0]}"
  if require_cmd realpath; then
    self="$(realpath "$self")"
  fi

  local nested_server="spec_preview_${USER}_$$"
  local nested_session="popup"
  local state_dir="${TMPDIR:-/tmp}/tmux_spec_preview_${USER}_${nested_server}"

  export STATE_DIR="$state_dir"
  export NESTED_SERVER="$nested_server"
  export SPEC_PREVIEW_SELF="$self"

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  [[ -d "$STATE_DIR" ]] || die "无法创建 STATE_DIR：$STATE_DIR"

  cleanup() {
    local sd="${STATE_DIR:-}"
    local ns="${NESTED_SERVER:-}"
    if [[ -n "${sd:-}" ]]; then
      rm -rf "$sd" 2>/dev/null || true
    fi
    if [[ -n "${ns:-}" ]]; then
      command tmux -L "$ns" kill-server >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT SIGINT SIGTERM SIGHUP

  state_write repo_root "$repo_root"
  state_write specs_dir "$specs_dir"
  state_write selected_us_code "ALL"
  state_write selected_task_line ""
  state_write us_editor_open "0"
  state_write task_editor_open "0"
  state_write artifact_editor_open "0"
  state_write closing "0"
  state_write view_mode "board"
  state_write selected_artifact_relpath ""

  local initial_spec
  initial_spec="$(bash "$self" __list_specs | head -n 1 | awk -F'\t' '{print $2}' 2>/dev/null || true)"
  if [[ -n "${initial_spec:-}" ]]; then
    state_write selected_spec_id "$initial_spec"
  fi

  local new_session_err new_session_rc
  new_session_err=""
  set +e
  new_session_err="$(command tmux -L "$nested_server" -f /dev/null new-session -d -s "$nested_session" -n spec 2>&1)"
  new_session_rc=$?
  set -e
  if ((new_session_rc != 0)); then
    die "内嵌 tmux 启动失败（rc=$new_session_rc）：${new_session_err:-未知错误}"
  fi
  command tmux -L "$nested_server" set -g status off >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g mouse on >/dev/null 2>&1 || true
  # 滚轮策略：
  # - 列表（fzf pane）：默认透传给程序，避免误进 copy-mode；
  # - PREVIEW pane：允许滚轮自动进入 copy-mode 并滚动（否则看长文件很痛苦）；
  # - 已在 copy-mode：继续滚动。
  command tmux -L "$nested_server" bind-key -n WheelUpPane \
    if-shell -F "#{pane_in_mode}" \
    "send-keys -X scroll-up" \
    "if-shell -F '#{==:#{pane_title},PREVIEW}' 'copy-mode -e; send-keys -X scroll-up' 'send-keys -M'" \
    >/dev/null 2>&1 || true
  command tmux -L "$nested_server" bind-key -n WheelDownPane \
    if-shell -F "#{pane_in_mode}" \
    "send-keys -X scroll-down" \
    "if-shell -F '#{==:#{pane_title},PREVIEW}' 'copy-mode -e; send-keys -X scroll-down' 'send-keys -M'" \
    >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g focus-events on >/dev/null 2>&1 || true
  # 兜底退出：当焦点落在 PREVIEW 等非 fzf pane 时，仍可退出整个 popup。
  command tmux -L "$nested_server" bind-key -n C-g kill-server >/dev/null 2>&1 || true
  command tmux -L "$nested_server" bind-key -n Escape if-shell -F "#{==:#{pane_title},PREVIEW}" "kill-server" "send-keys Escape" >/dev/null 2>&1 || true
  command tmux -L "$nested_server" bind-key -n C-c if-shell -F "#{==:#{pane_title},PREVIEW}" "kill-server" "send-keys C-c" >/dev/null 2>&1 || true

  command tmux -L "$nested_server" setw -g pane-border-status top >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g pane-border-format ' #{pane_title} ' >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g pane-border-style fg=colour238 >/dev/null 2>&1 || true
  command tmux -L "$nested_server" set -g pane-active-border-style fg=colour45 >/dev/null 2>&1 || true

  # Layout: spec | us | task
  command tmux -L "$nested_server" split-window -h -p 70 -t "$nested_session:0.0" -d >/dev/null 2>&1 || true
  command tmux -L "$nested_server" split-window -h -p 50 -t "$nested_session:0.1" -d >/dev/null 2>&1 || true

  local spec_pane us_pane task_pane
  spec_pane="$(command tmux -L "$nested_server" display-message -p -t "$nested_session:0.0" '#{pane_id}' 2>/dev/null || true)"
  us_pane="$(command tmux -L "$nested_server" display-message -p -t "$nested_session:0.1" '#{pane_id}' 2>/dev/null || true)"
  task_pane="$(command tmux -L "$nested_server" display-message -p -t "$nested_session:0.2" '#{pane_id}' 2>/dev/null || true)"

  local task_preview_pane
  task_preview_pane="$(
    command tmux -L "$nested_server" split-window -v -p 45 -t "$task_pane" -d -P -F '#{pane_id}' 2>/dev/null || true
  )"
  if [[ -z "${task_preview_pane:-}" ]]; then
    task_preview_pane="$(command tmux -L "$nested_server" display-message -p -t "$nested_session:0.3" '#{pane_id}' 2>/dev/null || true)"
  fi

  state_write spec_pane_id "$spec_pane"
  state_write us_pane_id "$us_pane"
  state_write task_pane_id "$task_pane"
  state_write task_preview_pane_id "$task_preview_pane"

  command tmux -L "$nested_server" select-pane -t "$spec_pane" -T "SPEC" >/dev/null 2>&1 || true
  command tmux -L "$nested_server" select-pane -t "$us_pane" -T "US" >/dev/null 2>&1 || true
  command tmux -L "$nested_server" select-pane -t "$task_pane" -T "TASK" >/dev/null 2>&1 || true
  if [[ -n "${task_preview_pane:-}" ]]; then
    command tmux -L "$nested_server" select-pane -t "$task_preview_pane" -T "PREVIEW" >/dev/null 2>&1 || true
  fi
  # 默认把焦点放回 SPEC，避免一进来就落到 PREVIEW。
  command tmux -L "$nested_server" select-pane -t "$spec_pane" >/dev/null 2>&1 || true

  command tmux -L "$nested_server" respawn-pane -k -t "$task_pane" \
    "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_pane" \
    >/dev/null 2>&1 || true
  if [[ -n "${task_preview_pane:-}" ]]; then
    command tmux -L "$nested_server" respawn-pane -k -t "$task_preview_pane" \
      "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __task_preview_pane" \
      >/dev/null 2>&1 || true
  fi

  command tmux -L "$nested_server" respawn-pane -k -t "$us_pane" \
    "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __us_pane" \
    >/dev/null 2>&1 || true

  command tmux -L "$nested_server" respawn-pane -k -t "$spec_pane" \
    "STATE_DIR='$state_dir' NESTED_SERVER='$nested_server' SPEC_PREVIEW_SELF='$self' bash '$self' __spec_pane" \
    >/dev/null 2>&1 || true

  set +e
  command tmux -L "$nested_server" -f /dev/null attach-session -t "$nested_session"
  rc=$?
  set -e

  if [[ "$(state_read closing "0")" == "1" ]]; then
    return 0
  fi
  if ((rc != 0)); then
    # 可能是用户用兜底快捷键 kill-server 主动退出；此时不弹错误。
    if command tmux -L "$nested_server" has-session -t "$nested_session" >/dev/null 2>&1; then
      printf '%s\n' "内嵌 tmux attach 失败（rc=$rc）。"
      pause
    fi
  fi
}

internal_cmd="${1:-}"
case "$internal_cmd" in
  __popup_ui)
    shift || true
    board_popup_ui "$@"
    exit 0
    ;;
  __spec_pane)
    shift || true
    board_spec_pane "$@"
    exit 0
    ;;
  __us_pane)
    shift || true
    board_us_pane "$@"
    exit 0
    ;;
  __task_pane)
    shift || true
    board_task_pane "$@"
    exit 0
    ;;
  __list_specs)
    shift || true
    board_list_specs "$@"
    exit 0
    ;;
  __list_us)
    shift || true
    board_list_us "$@"
    exit 0
    ;;
  __list_tasks)
    shift || true
    board_list_tasks "$@"
    exit 0
    ;;
  __spec_focus)
    shift || true
    board_spec_focus "$@"
    exit 0
    ;;
  __us_focus)
    shift || true
    board_us_focus "$@"
    exit 0
    ;;
  __open_spec)
    shift || true
    board_open_spec_at_line "$@"
    exit 0
    ;;
  __open_task)
    shift || true
    board_open_task_at_line "$@"
    exit 0
    ;;
  __focus_pane)
    shift || true
    board_focus_pane "$@"
    exit 0
    ;;
  __task_focus)
    shift || true
    board_task_focus "$@"
    exit 0
    ;;
  __task_preview_pane)
    shift || true
    board_task_preview_pane "$@"
    exit 0
    ;;
  __artifact_pane)
    shift || true
    artifacts_pane "$@"
    exit 0
    ;;
  __list_artifacts)
    shift || true
    artifacts_list_files "$@"
    exit 0
    ;;
  __artifact_focus)
    shift || true
    artifacts_file_focus "$@"
    exit 0
    ;;
  __artifact_preview_pane)
    shift || true
    artifacts_preview_pane "$@"
    exit 0
    ;;
  __open_artifact)
    shift || true
    artifacts_open_file "$@"
    exit 0
    ;;
  __toggle_view)
    shift || true
    ui_toggle_view "$@"
    exit 0
    ;;
  __close_popup)
    shift || true
    board_close_popup "$@"
    exit 0
    ;;
esac

spec_path=""
id=""
repo_root_override=""
mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      print_help
      exit 0
      ;;
    --repo-root)
      repo_root_override="${2:-}"
      if [[ -z "${repo_root_override:-}" ]]; then
        printf '%s\n' "--repo-root 需要路径参数"
        exit 0
      fi
      shift 2
      ;;
    --spec-path)
      spec_path="${2:-}"
      if [[ -z "${spec_path:-}" ]]; then
        printf '%s\n' "--spec-path 需要路径参数"
        exit 0
      fi
      shift 2
      ;;
    --mode)
      mode="${2:-}"
      if [[ -z "${mode:-}" ]]; then
        printf '%s\n' "--mode 需要参数（board/files）"
        exit 0
      fi
      shift 2
      ;;
    --board)
      mode="board"
      shift
      ;;
    --files)
      mode="files"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf '%s\n' "未知参数：$1"
      print_help
      exit 0
      ;;
    *)
      id="$1"
      shift
      ;;
  esac
done

need_cmd fzf
need_cmd rg
need_cmd bat

has_nvim=0
if command -v nvim >/dev/null 2>&1; then
  has_nvim=1
fi

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

tmux_client="${SPEC_PREVIEW_CLIENT:-}"
tmux_start_dir="${SPEC_PREVIEW_START_DIR:-}"
popup_active="0"
if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" ]]; then
  if [[ -z "${tmux_client:-}" ]]; then
    tmux_client="$(tmux display-message -p '#{client_name}' 2>/dev/null || true)"
  fi
  if [[ -z "${tmux_start_dir:-}" ]]; then
    tmux_start_dir="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)"
  fi
  popup_active="$(tmux display-message -p '#{popup_active}' 2>/dev/null || true)"
fi

in_popup=0
if [[ "${SPEC_PREVIEW_IN_POPUP:-0}" == "1" ]]; then
  in_popup=1
elif [[ -n "${tmux_client:-}" && "${popup_active:-0}" == "1" ]]; then
  in_popup=1
fi

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

tmux_open_list_popup() {
  if [[ -z "${tmux_client:-}" ]]; then
    return 1
  fi
  local start_dir="${tmux_start_dir:-}"
  local cmd
  cmd="bash $(sq "$script_path")"
  tmux run-shell -b "tmux display-popup -C -c $(sq "$tmux_client") >/dev/null 2>&1 || true; tmux display-popup -E -w 95% -h 90% -T $(sq "spec") -e $(sq "SPEC_PREVIEW_CLIENT=$tmux_client") -e $(sq "SPEC_PREVIEW_IN_POPUP=1") ${start_dir:+-e $(sq "SPEC_PREVIEW_START_DIR=$start_dir")} -c $(sq "$tmux_client") ${start_dir:+-d $(sq "$start_dir")} $(sq "$cmd") >/dev/null 2>&1 || true; true"
}

tmux_open_detail_popup() {
  if [[ -z "${tmux_client:-}" ]]; then
    return 1
  fi
  local chosen_spec="$1"
  local base
  base="$(basename "$chosen_spec")"
  local title="$base"
  if [[ "$base" =~ ^([0-9]{3})- ]]; then
    title="${BASH_REMATCH[1]}"
  fi
  local start_dir="${tmux_start_dir:-}"
  local cmd
  cmd="bash $(sq "$script_path") --spec-path $(sq "$chosen_spec")"
  tmux run-shell -b "tmux display-popup -C -c $(sq "$tmux_client") >/dev/null 2>&1 || true; tmux display-popup -E -w 95% -h 90% -T $(sq "$title") -e $(sq "SPEC_PREVIEW_CLIENT=$tmux_client") -e $(sq "SPEC_PREVIEW_IN_POPUP=1") ${start_dir:+-e $(sq "SPEC_PREVIEW_START_DIR=$start_dir")} -c $(sq "$tmux_client") ${start_dir:+-d $(sq "$start_dir")} $(sq "$cmd") >/dev/null 2>&1 || true; true"
}

repo_root=""

specs_dir=""
resolved_repo=""
resolved_repo="$(find_repo_paths "${tmux_start_dir:-$PWD}" "$repo_root_override" 2>/dev/null || true)"
if [[ -n "${resolved_repo:-}" ]]; then
  repo_root="${resolved_repo%%$'\t'*}"
  specs_dir="${resolved_repo#*$'\t'}"
else
  printf '%s\n' "找不到 specs 目录（请在含 specs/ 的仓库内运行；或用 --repo-root 指定）。"
  pause
  exit 0
fi

if [[ -z "${mode:-}" ]]; then
  if [[ "$in_popup" == "1" && -z "${spec_path:-}" && -z "${id:-}" ]]; then
    mode="board"
  else
    mode="files"
  fi
fi

if [[ "$mode" == "board" ]]; then
  export SPEC_PREVIEW_START_DIR="${tmux_start_dir:-$PWD}"
  export SPEC_PREVIEW_REPO_ROOT_OVERRIDE="$repo_root_override"
  board_popup_ui
  exit 0
fi

shopt -s nullglob

chosen_spec=""
matches=()
if [[ -n "${spec_path:-}" ]]; then
  if [[ "${spec_path}" != /* && -d "$specs_dir/$spec_path" ]]; then
    spec_path="$specs_dir/$spec_path"
  fi
  matches=("$spec_path")
elif [[ -n "${id:-}" ]]; then
  if [[ ! "$id" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "请输入数字编号，例如 70 / 070"
    pause
    exit 0
  fi
  num=$((10#$id))
  id3="$(printf "%03d" "$num")"
  matches=("$specs_dir"/"${id3}"-*)
  if ((${#matches[@]} == 0)); then
    printf '%s\n' "未找到 spec：$specs_dir/${id3}-*"
    pause
    exit 0
  fi
else
  matches=("$specs_dir"/[0-9][0-9][0-9]-*)
  if ((${#matches[@]} == 0)); then
    printf '%s\n' "未发现任何 spec：$specs_dir/<NNN-*>"
    pause
    exit 0
  fi
fi

rels=()
for p in "${matches[@]}"; do
  rels+=("$(basename "$p")")
done

pick_spec() {
  local picked
  set +e
  picked="$(
    printf '%s\n' "${rels[@]}" | fzf \
      --reverse \
      --exit-0 \
      --prompt='spec> ' \
      --height=60% \
      --border
  )"
  set -e
  printf '%s' "${picked:-}"
}

pick_file_in_spec() {
  local chosen_spec="$1"
  local back_hint="$2"

  cd "$chosen_spec"

  local files=()
  while IFS= read -r file; do
    [[ -n "${file:-}" ]] || continue
    files+=("$file")
  done < <(rg --files 2>/dev/null || true)

  if ((${#files[@]} == 0)); then
    printf '%s\n' "该 spec 目录下没有可浏览文件。"
    pause
    return 130
  fi

  fzf_args=(
    --prompt="$(basename "$chosen_spec")> "
    --preview 'bat --paging=never --style=numbers --color=always --line-range :400 -- {} 2>/dev/null'
    --preview-window=right:60%:wrap
    --bind 'ctrl-/:toggle-preview'
  )

  if [[ "$has_nvim" == "1" ]]; then
    fzf_args+=(
      --header "enter: nvim | ctrl-e: nvim(不退出) | ctrl-/: 预览开关 | esc: ${back_hint}"
      --bind 'ctrl-e:execute(nvim -- {} < /dev/tty > /dev/tty)+refresh-preview'
    )
  else
    fzf_args+=(
      --header "ctrl-/: 预览开关 | esc: ${back_hint}（未检测到 nvim，禁用编辑快捷键）"
    )
  fi

  set +e
  picked_file="$(printf '%s\n' "${files[@]}" | fzf "${fzf_args[@]}")"
  fzf_status=$?
  set -e

  if [[ "$fzf_status" -ne 0 || -z "${picked_file:-}" ]]; then
    return 130
  fi

  if [[ "$has_nvim" == "1" ]]; then
    nvim -- "$picked_file" < /dev/tty > /dev/tty
  fi
  return 0
}

if [[ "$in_popup" == "1" && -z "${spec_path:-}" ]]; then
  if ((${#rels[@]} == 1)); then
    chosen_spec="$specs_dir/${rels[0]}"
  else
    picked="$(pick_spec)"
    if [[ -z "${picked:-}" ]]; then
      exit 0
    fi
    chosen_spec="$specs_dir/$picked"
  fi

  if [[ ! -d "$chosen_spec" ]]; then
    printf '%s\n' "目录不存在：$chosen_spec"
    pause
    exit 0
  fi

  tmux_open_detail_popup "$chosen_spec"
  exit 0
fi

while true; do
  if ((${#rels[@]} == 1)); then
    chosen_spec="$specs_dir/${rels[0]}"
  else
    picked="$(pick_spec)"
    if [[ -z "${picked:-}" ]]; then
      exit 0
    fi
    chosen_spec="$specs_dir/$picked"
  fi

  if [[ ! -d "$chosen_spec" ]]; then
    printf '%s\n' "目录不存在：$chosen_spec"
    pause
    exit 0
  fi

  if [[ "$in_popup" == "1" ]]; then
    if ! pick_file_in_spec "$chosen_spec" "返回 spec 列表"; then
      tmux_open_list_popup
    fi
    exit 0
  fi

  if ((${#rels[@]} == 1)); then
    back_hint="退出"
  else
    back_hint="返回 spec 列表"
  fi

  if ! pick_file_in_spec "$chosen_spec" "$back_hint"; then
    if ((${#rels[@]} == 1)); then
      exit 0
    fi
    continue
  fi

  exit 0
done
