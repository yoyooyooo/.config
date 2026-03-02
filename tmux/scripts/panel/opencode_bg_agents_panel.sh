#!/usr/bin/env bash
# desc: 后台/bg/oMo：实时观测当前 pane 关联的 background subagent（数量 + 明细）
# usage: 在 M-p 面板选择；s 列表跳转，q/Esc 退出，r 手动刷新
# note: 优先读取 ORIGIN_PANE_ID（由 M-p 注入），并先探测该 pane 的 opencode 进程树
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
  command -v "$1" >/dev/null 2>&1
}

truncate_text() {
  local text="${1:-}"
  local max_len="${2:-40}"
  if ((${#text} <= max_len)); then
    printf '%s' "$text"
    return 0
  fi
  printf '%s…' "${text:0:max_len-1}"
}

detect_origin_pane() {
  local pane_id="${ORIGIN_PANE_ID:-}"
  if [[ -z "${pane_id}" || "${pane_id}" != %* ]]; then
    pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
  fi
  printf '%s' "$pane_id"
}

collect_descendant_pids() {
  local root_pid="$1"
  local -a queue=()
  local -a all=()
  local seen=$'\n'
  local pid child

  [[ -n "$root_pid" ]] || return 0
  queue+=("$root_pid")
  all+=("$root_pid")
  seen+="${root_pid}"$'\n'

  while ((${#queue[@]} > 0)); do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r child; do
      [[ -n "${child:-}" ]] || continue
      case "$seen" in
        *$'\n'"$child"$'\n'*) continue ;;
      esac
      seen+="${child}"$'\n'
      queue+=("$child")
      all+=("$child")
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  done

  printf '%s\n' "${all[@]}"
}

build_opencode_probe() {
  local pane_pid="$1"
  local cmds=""
  local matched=""
  local pid cmd

  [[ -n "${pane_pid:-}" ]] || {
    printf '%s\n' "未找到 pane pid"
    printf '%s\n' ""
    return 0
  }

  while IFS= read -r pid; do
    [[ -n "${pid:-}" ]] || continue
    cmd="$(ps -o command= -p "$pid" 2>/dev/null | head -n1 || true)"
    [[ -n "${cmd:-}" ]] || continue
    cmds+="${cmd}"$'\n'
    if [[ "$cmd" =~ (^|[[:space:]/])(opencode|codex)([[:space:]]|$) ]] || [[ "$cmd" == *"oh-my-opencode"* ]]; then
      matched+="${cmd}"$'\n'
    fi
  done < <(collect_descendant_pids "$pane_pid")

  if [[ -n "${matched}" ]]; then
    printf '%s\n' "已检测到 opencode 相关进程："
    printf '%s' "$matched" | awk 'NF' | head -n 3
  else
    printf '%s\n' "未检测到明确的 opencode 进程（可能在 shell 空闲态）"
    if [[ -n "${cmds}" ]]; then
      printf '%s\n' "当前进程链（前 3 行）："
      printf '%s' "$cmds" | awk 'NF' | head -n 3
    fi
  fi
}

select_and_jump_subagent() {
  local origin_client="${ORIGIN_CLIENT:-}"
  local rows selected target pane_id

  if ! require_cmd fzf; then
    tmux display-message "未安装 fzf，无法进入选择列表"
    return 1
  fi

  rows="$(
    tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_id}\t#{pane_active}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}' 2>/dev/null | \
    while IFS=$'\t' read -r s_name w_idx w_name p_idx p_id active cmd title p_path; do
      [[ -n "${p_id:-}" ]] || continue
      [[ "${title:-}" == omo-subagent-* ]] || continue
      target="${s_name}:${w_idx}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$target" \
        "$p_id" \
        "${active:-0}" \
        "${cmd:-}" \
        "${title#omo-subagent-}" \
        "${w_name:-}" \
        "${p_path:-}"
    done
  )"

  if [[ -z "${rows:-}" ]]; then
    tmux display-message "当前没有可跳转的 oMo subagent pane"
    return 1
  fi

  selected="$(
    printf '%s\n' "$rows" | fzf \
      --reverse \
      --exit-0 \
      --delimiter=$'\t' \
      --with-nth=1,2,3,4,5,6 \
      --prompt='subagent> ' \
      --header=$'Enter=跳转  Esc=返回' \
      --preview 'tmux capture-pane -p -t {2} -S -200 2>/dev/null | tail -n 200' \
      --preview-window='down,70%,wrap,follow'
  )" || true

  if [[ -z "${selected:-}" ]]; then
    return 1
  fi

  target="${selected%%$'\t'*}"
  pane_id="$(printf '%s' "$selected" | cut -f2)"
  [[ -n "${target:-}" && -n "${pane_id:-}" ]] || return 1

  if [[ -n "${origin_client:-}" ]]; then
    tmux switch-client -c "$origin_client" -t "$target" >/dev/null 2>&1 || tmux switch-client -t "$target" >/dev/null 2>&1 || true
  else
    tmux switch-client -t "$target" >/dev/null 2>&1 || true
  fi
  tmux select-pane -t "$pane_id" >/dev/null 2>&1 || true
  return 0
}

render_panel() {
  local origin_pane="$1"
  local origin_session_id origin_window_id origin_cmd origin_title origin_path origin_pid
  local now all_panes line
  local global_count=0
  local origin_window_count=0
  local -a rows_origin=()
  local -a rows_other=()

  origin_session_id="$(tmux display-message -p -t "$origin_pane" '#{session_id}' 2>/dev/null || true)"
  origin_window_id="$(tmux display-message -p -t "$origin_pane" '#{window_id}' 2>/dev/null || true)"
  origin_cmd="$(tmux display-message -p -t "$origin_pane" '#{pane_current_command}' 2>/dev/null || true)"
  origin_title="$(tmux display-message -p -t "$origin_pane" '#{pane_title}' 2>/dev/null || true)"
  origin_path="$(tmux display-message -p -t "$origin_pane" '#{pane_current_path}' 2>/dev/null || true)"
  origin_pid="$(tmux display-message -p -t "$origin_pane" '#{pane_pid}' 2>/dev/null || true)"
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  all_panes="$(tmux list-panes -a -F $'#{session_id}\t#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_current_command}\t#{pane_title}' 2>/dev/null || true)"

  while IFS= read -r line; do
    local s_id w_id p_id active cmd title short_title row
    [[ -n "${line:-}" ]] || continue
    IFS=$'\t' read -r s_id w_id p_id active cmd title <<<"$line"
    [[ -n "${p_id:-}" ]] || continue
    [[ "${title:-}" == omo-subagent-* ]] || continue

    global_count=$((global_count + 1))
    short_title="${title#omo-subagent-}"
    row="$(printf '%-6s %-3s %-12s %-26s' "$p_id" "${active:-0}" "$(truncate_text "$cmd" 12)" "$(truncate_text "$short_title" 26)")"

    if [[ "${s_id:-}" == "${origin_session_id:-}" && "${w_id:-}" == "${origin_window_id:-}" ]]; then
      origin_window_count=$((origin_window_count + 1))
      rows_origin+=("$row")
    else
      rows_other+=("$row")
    fi
  done <<<"$all_panes"

  printf '\033[H\033[2J'
  printf 'oMo Background Subagent Panel\n'
  printf '时间: %s\n' "$now"
  printf '按键: s 选择并跳转 | q/Esc 退出 | r 刷新\n'
  printf '\n'
  printf 'Origin Pane: %s  CMD: %s\n' "$origin_pane" "${origin_cmd:-unknown}"
  printf 'Title: %s\n' "$(truncate_text "${origin_title:-}" 72)"
  printf 'Path : %s\n' "$(truncate_text "${origin_path:-}" 72)"
  printf '\n'
  build_opencode_probe "$origin_pid"
  printf '\n'
  printf 'Subagents(标题匹配 omo-subagent-*): 全局=%d  同窗口=%d  其他窗口=%d\n' "$global_count" "$origin_window_count" "$((global_count - origin_window_count))"
  printf '\n'
  printf '%-6s %-3s %-12s %-26s\n' "Pane" "A" "Cmd" "Title"
  printf '%s\n' "---------------------------------------------------------------"

  if ((${#rows_origin[@]} == 0)); then
    printf '%s\n' "(当前 origin window 暂无 subagent pane)"
  else
    local r
    for r in "${rows_origin[@]}"; do
      printf '%s\n' "$r"
    done
  fi

  if ((${#rows_other[@]} > 0)); then
    printf '\n'
    printf '%s\n' "Other Windows (前 8 条):"
    local idx=0
    local other_row
    for other_row in "${rows_other[@]}"; do
      printf '%s\n' "$other_row"
      idx=$((idx + 1))
      if ((idx >= 8)); then
        break
      fi
    done
  fi
}

if ! require_cmd tmux; then
  die "找不到 tmux。"
fi
if ! require_cmd ps; then
  die "找不到 ps。"
fi
if ! require_cmd pgrep; then
  die "找不到 pgrep。"
fi

origin_pane_id="$(detect_origin_pane)"
if [[ -z "${origin_pane_id:-}" || "${origin_pane_id}" != %* ]]; then
  die "无法确定 origin pane。请从 tmux 内通过 M-p 面板运行。"
fi
if ! tmux display-message -p -t "$origin_pane_id" '#{pane_id}' >/dev/null 2>&1; then
  die "origin pane 不存在：${origin_pane_id}"
fi

while true; do
  render_panel "$origin_pane_id"
  if IFS= read -r -s -n 1 -t 1 key; then
    case "$key" in
      q|Q) exit 0 ;;
      $'\e') exit 0 ;;
      r|R) ;;
      s|S)
        if select_and_jump_subagent; then
          exit 0
        fi
        ;;
      *) ;;
    esac
  fi
done
