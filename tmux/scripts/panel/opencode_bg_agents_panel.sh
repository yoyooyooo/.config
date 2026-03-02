#!/usr/bin/env bash
# desc: 后台/bg/oMo：subagent 交互选择器（上下选择 + 回车跳转）
# usage: 在 M-p 面板选择；↑↓ 选择，Enter 跳转，Ctrl-r 刷新，Esc 退出
# note: 轮询在后台更新快照，不再前台闪屏
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

is_strict_subagent_title() {
  local title="${1:-}"
  [[ "$title" == omo-subagent-* ]]
}

is_opencode_like_pane() {
  local cmd="${1:-}"
  local title="${2:-}"
  if [[ "$cmd" == "opencode" || "$cmd" == "codex" ]]; then
    return 0
  fi
  if [[ "$title" == "OpenCode" || "$title" == OC\ \|* ]]; then
    return 0
  fi
  return 1
}

collect_tree_pids() {
  local root_pid="$1"
  local -a queue=()
  local -a all=()
  local seen=$'\n'
  local pid child

  [[ -n "${root_pid:-}" ]] || return 0
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

pane_has_engine_process() {
  local pane_pid="$1"
  local pid cmd
  [[ -n "${pane_pid:-}" ]] || return 1

  while IFS= read -r pid; do
    [[ -n "${pid:-}" ]] || continue
    cmd="$(ps -o command= -p "$pid" 2>/dev/null | head -n1 || true)"
    [[ -n "${cmd:-}" ]] || continue
    if [[ "$cmd" =~ (^|[[:space:]/])(opencode|codex)([[:space:]]|$) ]] || [[ "$cmd" == *"oh-my-opencode"* ]]; then
      return 0
    fi
  done < <(collect_tree_pids "$pane_pid")

  return 1
}

classify_pane_kind() {
  local pane_id="$1"
  local cmd="$2"
  local title="$3"
  local engine_alive="$4"
  local origin_pane="$5"

  if is_strict_subagent_title "$title"; then
    printf 'S'
    return 0
  fi

  if [[ "$pane_id" != "$origin_pane" ]] && is_opencode_like_pane "$cmd" "$title"; then
    printf 'H'
    return 0
  fi

  if [[ "$pane_id" != "$origin_pane" ]] && [[ "${engine_alive:-0}" == "1" ]]; then
    printf 'P'
    return 0
  fi

  printf ''
  return 0
}

compute_pane_tail_hash() {
  local pane_id="$1"
  local captured hash
  captured="$(tmux capture-pane -p -t "$pane_id" -S -80 2>/dev/null | tail -n 80 || true)"
  if require_cmd md5; then
    hash="$(printf '%s' "$captured" | md5 2>/dev/null | awk '{print $NF}')"
  elif require_cmd shasum; then
    hash="$(printf '%s' "$captured" | shasum 2>/dev/null | awk '{print $1}')"
  else
    hash="$(printf '%s' "$captured" | wc -c | awk '{print $1}')"
  fi
  printf '%s' "${hash:-0}"
}

refresh_snapshot_once() {
  local origin_pane="$1"
  local rows_file="$2"
  local summary_file="$3"
  local idle_threshold="${4:-8}"

  local rows_tmp="${rows_file}.tmp"
  local summary_tmp="${summary_file}.tmp"
  local line now_ts
  local total=0 strict=0 heuristic=0 proc=0 candidates=0 opencode_like=0
  local run_count=0 idle_count=0 done_count=0

  : >"$rows_tmp"
  now_ts="$(date +%s)"

  while IFS= read -r line; do
    local s_name w_idx w_name p_idx p_id active cmd title p_path pane_pid kind target clean_title
    local engine_alive status hash prev_line prev_hash prev_changed changed_at age
    [[ -n "${line:-}" ]] || continue
    IFS=$'\t' read -r s_name w_idx w_name p_idx p_id active cmd title p_path pane_pid <<<"$line"
    [[ -n "${p_id:-}" ]] || continue

    if is_opencode_like_pane "${cmd:-}" "${title:-}"; then
      opencode_like=$((opencode_like + 1))
    fi

    if pane_has_engine_process "${pane_pid:-}"; then
      engine_alive=1
    else
      engine_alive=0
    fi

    kind="$(classify_pane_kind "$p_id" "${cmd:-}" "${title:-}" "$engine_alive" "$origin_pane")"
    [[ -n "${kind:-}" ]] || continue

    total=$((total + 1))
    case "$kind" in
      S) strict=$((strict + 1)) ;;
      H) heuristic=$((heuristic + 1)) ;;
      P) proc=$((proc + 1)) ;;
    esac

    hash="$(compute_pane_tail_hash "$p_id")"
    prev_line="$(awk -F '\t' -v id="$p_id" '$2==id {print; exit}' "$rows_file" 2>/dev/null || true)"
    prev_hash="$(printf '%s' "$prev_line" | cut -f10)"
    prev_changed="$(printf '%s' "$prev_line" | cut -f11)"

    if [[ "$engine_alive" != "1" ]]; then
      status="DONE"
      done_count=$((done_count + 1))
      changed_at="${prev_changed:-$now_ts}"
    elif [[ -z "${prev_hash:-}" || "$hash" != "$prev_hash" ]]; then
      status="RUN"
      run_count=$((run_count + 1))
      changed_at="$now_ts"
    else
      changed_at="${prev_changed:-$now_ts}"
      age=$((now_ts - changed_at))
      if (( age >= idle_threshold )); then
        status="IDLE"
        idle_count=$((idle_count + 1))
      else
        status="RUN"
        run_count=$((run_count + 1))
      fi
    fi

    if [[ "$p_id" == "$origin_pane" ]]; then
      continue
    fi

    target="${s_name}:${w_idx}"
    clean_title="${title#omo-subagent-}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$target" \
      "$p_id" \
      "$kind" \
      "$status" \
      "${active:-0}" \
      "$(truncate_text "${cmd:-}" 20)" \
      "$(truncate_text "${clean_title:-}" 46)" \
      "$(truncate_text "${w_name:-}" 20)" \
      "$(truncate_text "${p_path:-}" 56)" \
      "$hash" \
      "$changed_at" \
      >>"$rows_tmp"

    candidates=$((candidates + 1))
  done < <(tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_id}\t#{pane_active}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}\t#{pane_pid}' 2>/dev/null || true)

  {
    printf '识别: 全部=%d (S=%d H=%d P=%d)  可切=%d  opencode-like(含当前)=%d\n' "$total" "$strict" "$heuristic" "$proc" "$candidates" "$opencode_like"
    printf '状态: RUN=%d IDLE=%d DONE=%d (IDLE阈值=%ss)\n' "$run_count" "$idle_count" "$done_count" "$idle_threshold"
    printf '按键: ↑↓ 选择  Enter 跳转  Ctrl-r 刷新(后台轮询快照)  Esc 退出\n'
    printf 'Kind: S=严格(omo-subagent-*) H=经验(title/cmd) P=进程树(opencode/codex)\n'
  } >"$summary_tmp"

  mv -f "$rows_tmp" "$rows_file"
  mv -f "$summary_tmp" "$summary_file"
}

start_snapshot_worker() {
  local origin_pane="$1"
  local rows_file="$2"
  local summary_file="$3"
  local interval_sec="${4:-2}"

  while true; do
    refresh_snapshot_once "$origin_pane" "$rows_file" "$summary_file"
    sleep "$interval_sec"
  done
}

jump_to_pane() {
  local origin_client="$1"
  local target="$2"
  local pane_id="$3"

  if [[ -n "${origin_client:-}" ]]; then
    tmux switch-client -c "$origin_client" -t "$target" >/dev/null 2>&1 || tmux switch-client -t "$target" >/dev/null 2>&1 || true
  else
    tmux switch-client -t "$target" >/dev/null 2>&1 || true
  fi

  tmux select-pane -t "$pane_id" >/dev/null 2>&1 || true
  tmux display-message "已切换: ${target} ${pane_id}"
}

run_picker() {
  local origin_pane="$1"
  local origin_client="${ORIGIN_CLIENT:-}"

  if ! require_cmd fzf; then
    die "未安装 fzf，无法使用交互选择。"
  fi

  local rows_file summary_file
  rows_file="$(mktemp -t omo-bg-rows.XXXXXX)"
  summary_file="$(mktemp -t omo-bg-summary.XXXXXX)"

  refresh_snapshot_once "$origin_pane" "$rows_file" "$summary_file"

  start_snapshot_worker "$origin_pane" "$rows_file" "$summary_file" "2" &
  local worker_pid=$!

  cleanup() {
    kill "${worker_pid:-}" >/dev/null 2>&1 || true
    rm -f "${rows_file:-}" "${summary_file:-}" "${rows_file:-}.tmp" "${summary_file:-}.tmp" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM HUP

  local origin_cmd origin_title origin_path summary_line header selected target pane_id
  origin_cmd="$(tmux display-message -p -t "$origin_pane" '#{pane_current_command}' 2>/dev/null || true)"
  origin_title="$(tmux display-message -p -t "$origin_pane" '#{pane_title}' 2>/dev/null || true)"
  origin_path="$(tmux display-message -p -t "$origin_pane" '#{pane_current_path}' 2>/dev/null || true)"
  summary_line="$(tr '\n' ' ' < "$summary_file" | sed 's/[[:space:]]\+/ /g')"

  header="Origin: ${origin_pane} cmd=${origin_cmd:-unknown} title=$(truncate_text "${origin_title:-}" 36) | ${summary_line}"

  selected="$({
    cat "$rows_file"
  } | fzf \
      --reverse \
      --exit-0 \
      --delimiter=$'\t' \
      --with-nth=1,2,3,4,5,6,7,8 \
      --prompt='subagent> ' \
      --header "$header" \
      --header-lines=0 \
      --preview 'printf "PATH: %s\\n----\\n" {9}; tmux capture-pane -p -t {2} -S -200 2>/dev/null | tail -n 200' \
      --preview-window='down,70%,wrap,follow' \
      --bind "start:reload(cat '$rows_file')" \
      --bind "ctrl-r:reload(cat '$rows_file')"
  )" || true

  if [[ -z "${selected:-}" ]]; then
    tmux display-message "未选择目标（已退出）"
    return 0
  fi

  target="$(printf '%s' "$selected" | cut -f1)"
  pane_id="$(printf '%s' "$selected" | cut -f2)"

  if [[ -z "${target:-}" || -z "${pane_id:-}" || "${pane_id}" != %* ]]; then
    tmux display-message "选择结果无效，未切换"
    return 1
  fi

  jump_to_pane "$origin_client" "$target" "$pane_id"
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

run_picker "$origin_pane_id"
