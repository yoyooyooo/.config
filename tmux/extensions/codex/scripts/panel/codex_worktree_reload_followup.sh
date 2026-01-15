#!/usr/bin/env bash
# desc: 创建/复用 worktree，并在该目录重载 Codex，然后自动发送 follow-up
# usage:
#   ORIGIN_PANE_ID=%123 bash ~/.config/tmux/extensions/codex/scripts/panel/codex_worktree_reload_followup.sh <branch> "<follow-up>"
#   ORIGIN_PANE_ID=%123 bash ~/.config/tmux/extensions/codex/scripts/panel/codex_worktree_reload_followup.sh <branch>   # follow-up 将用 tmux-kit 弹框输入
#   ORIGIN_PANE_ID=%123 bash ~/.config/tmux/extensions/codex/scripts/panel/codex_worktree_reload_followup.sh            # 分支与 follow-up 都会弹框输入（适合从 M-p 面板直接运行）
# env:
#   WT_MODE=auto|add|new         # 默认 auto（本地分支存在→add；否则→new）
#   WT_START_POINT=<ref>         # WT_MODE=new 或 auto 且分支不存在时使用；为空则弹框询问
#   WT_SCRIPT=<path>             # 覆盖 git-worktree-kit 的 wt 脚本路径
#   CODEX_WT_RELOAD_NONINTERACTIVE=1  # 不 pause，出错 exit 1（适合脚本化调用）
set -euo pipefail

noninteractive() {
  [[ "${CODEX_WT_RELOAD_NONINTERACTIVE:-}" == "1" ]]
}

pause() {
  if noninteractive; then
    return 0
  fi
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

die() {
  printf '%s\n' "$1"
  pause
  if noninteractive; then
    exit 1
  fi
  exit 0
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

ensure_tmux_env_for_tmux_kit() {
  [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] && return 0

  require_cmd tmux || return 0

  if [[ -z "${TMUX_PANE:-}" ]]; then
    local pane="${ORIGIN_PANE_ID:-}"
    if [[ -z "${pane:-}" || "$pane" == *"#{"* || "$pane" != %* ]]; then
      pane="$(tmux show -gqv @panel_origin_pane_id 2>/dev/null || true)"
    fi
    if [[ -z "${pane:-}" || "$pane" == *"#{"* || "$pane" != %* ]]; then
      pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
    fi
    if [[ -n "${pane:-}" && "$pane" == %* ]]; then
      export TMUX_PANE="$pane"
    fi
  fi

  if [[ -z "${TMUX:-}" ]]; then
    local socket pid session_id pane_target
    pane_target="${TMUX_PANE:-}"
    if [[ -n "${pane_target:-}" ]]; then
      socket="$(tmux display-message -p -t "$pane_target" '#{socket_path}' 2>/dev/null || true)"
      pid="$(tmux display-message -p -t "$pane_target" '#{pid}' 2>/dev/null || true)"
      session_id="$(tmux display-message -p -t "$pane_target" '#{session_id}' 2>/dev/null || true)"
    else
      socket="$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)"
      pid="$(tmux display-message -p '#{pid}' 2>/dev/null || true)"
      session_id="$(tmux display-message -p '#{session_id}' 2>/dev/null || true)"
    fi
    session_id="${session_id#\\$}"
    if [[ -n "${socket:-}" ]]; then
      export TMUX="${socket},${pid:-0},${session_id:-0}"
    fi
  fi
}

tmux_display() {
  local pane="$1"
  local fmt="$2"
  tmux display-message -p -t "$pane" "$fmt" 2>/dev/null || true
}

resolve_origin_pane() {
  local pane="${ORIGIN_PANE_ID:-}"
  if [[ -z "${pane:-}" || "$pane" == *"#{"* || "$pane" != %* ]]; then
    pane="$(tmux show -gqv @panel_origin_pane_id 2>/dev/null || true)"
  fi
  if [[ -z "${pane:-}" || "$pane" == *"#{"* || "$pane" != %* ]]; then
    pane="${TMUX_PANE:-}"
  fi
  if [[ -z "${pane:-}" || "$pane" == *"#{"* || "$pane" != %* ]]; then
    die "缺少 ORIGIN_PANE_ID（期望形如 %85）。"
  fi
  printf '%s' "$pane"
}

resolve_repo_root() {
  local cwd="$1"
  local common_dir
  common_dir="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "${common_dir:-}" ]]; then
    local main_root
    main_root="$(cd -- "$(dirname "$common_dir")" 2>/dev/null && pwd || true)"
    if [[ -n "${main_root:-}" ]]; then
      local top
      top="$(git -C "$main_root" rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ -n "${top:-}" ]]; then
        printf '%s' "$top"
        return 0
      fi
    fi
  fi

  local root
  root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "${root:-}" ]] || return 1
  printf '%s' "$root"
}

resolve_wt_script() {
  local candidate="${WT_SCRIPT:-}"
  if [[ -n "${candidate:-}" ]]; then
    [[ -x "$candidate" ]] || die "WT_SCRIPT 不可执行：$candidate"
    printf '%s' "$candidate"
    return 0
  fi

  local codex_home="${CODEX_HOME:-}"
  if [[ -n "${codex_home:-}" && -x "${codex_home}/skills/git-worktree-kit/scripts/wt" ]]; then
    printf '%s' "${codex_home}/skills/git-worktree-kit/scripts/wt"
    return 0
  fi

  candidate="$HOME/.codex/skills/git-worktree-kit/scripts/wt"
  [[ -x "$candidate" ]] || die "找不到 git-worktree-kit 的 wt：$candidate（可用 WT_SCRIPT 覆盖）"
  printf '%s' "$candidate"
}

resolve_session_probe() {
  local script_dir
  script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local candidate="$script_dir/../tmux_codex_session_id.py"
  if [[ -f "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  candidate="$HOME/.config/tmux/extensions/codex/scripts/tmux_codex_session_id.py"
  [[ -f "$candidate" ]] || die "找不到脚本：$candidate"
  printf '%s' "$candidate"
}

existing_worktree_path_for_branch() {
  local repo_root="$1"
  local branch="$2"

  local refs=()
  if [[ "$branch" == refs/* ]]; then
    refs+=("$branch")
  else
    refs+=("refs/heads/$branch" "refs/remotes/$branch" "refs/remotes/origin/$branch")
  fi

  local porcelain
  porcelain="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null || true)"
  [[ -n "${porcelain:-}" ]] || return 1

  local ref
  for ref in "${refs[@]}"; do
    local out
    out="$(
      awk -v target_ref="$ref" '
        $1 == "worktree" { path = $2; next }
        $1 == "branch" && $2 == target_ref { print path; exit }
      ' <<<"$porcelain"
    )"
    if [[ -n "${out:-}" ]]; then
      printf '%s' "$out"
      return 0
    fi
  done
  return 1
}

branch_exists_local() {
  local repo_root="$1"
  local branch="$2"
  git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null
}

prompt_via_tmux_kit() {
  local title="$1"
  local message="$2"
  local choices_json="$3"

  local popup="$HOME/.codex/skills/tmux-kit/scripts/popup_select.py"
  [[ -f "$popup" ]] || die "找不到 tmux-kit：$popup"
  require_cmd python3 || die "找不到 python3。"
  ensure_tmux_env_for_tmux_kit

  local result_json
  result_json="$(
    python3 "$popup" <<JSON
{"title": ${title}, "message": ${message}, "mode":"single", "allow_custom_input": true, "choices": ${choices_json}}
JSON
  )"

  local value rc
  set +e
  value="$(
    python3 - "$result_json" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception as e:
    print(f"tmux-kit 返回异常：无法解析 JSON（{e}）", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print("tmux-kit 返回异常：payload 不是对象", file=sys.stderr)
    sys.exit(2)

if data.get("cancelled"):
    sys.exit(1)

if not data.get("ok", False):
    err = data.get("error") or {}
    code = (err.get("code") or "unknown").strip()
    msg = (err.get("message") or "unknown error").strip()
    print(f"tmux-kit 错误：{code} {msg}", file=sys.stderr)
    sys.exit(2)

result_type = data.get("result_type") or ""
if result_type == "custom_input":
    v = (data.get("custom_input_trimmed") or data.get("custom_input") or "").strip()
else:
    selected = data.get("selected_values") or []
    v = str(selected[0]).strip() if isinstance(selected, list) and selected else ""

if not v:
    print("tmux-kit 错误：未返回有效输入", file=sys.stderr)
    sys.exit(2)

print(v)
sys.exit(0)
PY
  )"
  rc=$?
  set -e
  if [[ "$rc" != "0" ]]; then
    return "$rc"
  fi

  printf '%s' "$value"
  return 0
}

choose_start_point_if_needed() {
  local repo_root="$1"
  local new_branch="$2"
  local current_branch
  current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ "$current_branch" == "HEAD" ]] && current_branch=""

  local choices=()
  if [[ -n "${current_branch:-}" ]]; then
    choices+=("{\"label\":\"当前分支（${current_branch}）\",\"value\":\"__HEAD__\",\"detail\":\"等价于使用当前工作区 HEAD（wt new 省略 start-point）\"}")
  else
    choices+=("{\"label\":\"当前工作区 HEAD\",\"value\":\"__HEAD__\",\"detail\":\"wt new 省略 start-point\"}")
  fi

  if [[ -n "${new_branch:-}" ]]; then
    if git -C "$repo_root" show-ref --verify --quiet "refs/remotes/$new_branch" 2>/dev/null; then
      choices+=("{\"label\":\"$new_branch\",\"value\":\"$new_branch\",\"detail\":\"远端分支（与目标分支同名）\"}")
    elif git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$new_branch" 2>/dev/null; then
      choices+=("{\"label\":\"origin/$new_branch\",\"value\":\"origin/$new_branch\",\"detail\":\"远端分支（与目标分支同名）\"}")
    fi
  fi

  local b
  for b in main master dev develop; do
    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$b" 2>/dev/null; then
      choices+=("{\"label\":\"$b\",\"value\":\"$b\",\"detail\":\"本地分支\"}")
    elif git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null; then
      choices+=("{\"label\":\"origin/$b\",\"value\":\"origin/$b\",\"detail\":\"远端分支\"}")
    fi
  done

  local joined json title message
  joined="$(IFS=,; echo "${choices[*]}")"
  json="[${joined}]"
  title="$(json_quote "选择新分支起点（start-point）")"
  message="$(json_quote $'分支不存在，需要指定从哪里创建（Esc 取消）。\n提示：选择“当前工作区 HEAD”会让 wt new 省略 start-point。')"
  prompt_via_tmux_kit "$title" "$message" "$json"
}

prompt_followup_if_needed() {
  local title message choices
  title="$(json_quote "输入 follow-up")"
  message="$(json_quote $'reload 之后会把这段文字发给 Codex（单行）。\n- 直接输入后按 ctrl-o 提交\n- 或输入无匹配时按 Enter 提交\nEsc 取消。')"
  choices='["继续"]'
  prompt_via_tmux_kit "$title" "$message" "$choices"
}

prompt_branch_if_needed() {
  local repo_root="$1"
  local branches
  branches="$(git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)"
  if [[ -z "${branches//[[:space:]]/}" ]]; then
    branches="main"
  fi

  local choices_json
  choices_json="$(
    python3 -c 'import json,sys; items=[l.strip() for l in sys.stdin.read().splitlines() if l.strip()]; print(json.dumps(items, ensure_ascii=False))' <<<"$branches"
  )"

  local title message
  title="$(json_quote "选择/输入分支名")"
  message="$(json_quote $'创建 worktree 并重载 Codex。\n- 选择已有本地分支：直接创建 worktree\n- 自定义输入新分支名：会继续询问 start-point\nEsc 取消。')"
  prompt_via_tmux_kit "$title" "$message" "$choices_json"
}

wait_for_codex_session() {
  local pane="$1"
  local probe="$2"
  local max_tries="${3:-80}" # 80 * 0.15s ~= 12s
  local i
  for ((i = 0; i < max_tries; i++)); do
    if python3 "$probe" --pane "$pane" --json >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.15
  done
  return 1
}

pane_looks_idle() {
  local capture="$1"
  [[ -n "${capture:-}" ]] || return 1
  if printf '%s' "$capture" | grep -qiF -- "esc to interrupt"; then
    return 1
  fi
  if printf '%s' "$capture" | grep -qiF -- "again to interrupt"; then
    return 1
  fi
  printf '%s' "$capture" | grep -q -- "›"
}

wait_for_codex_prompt() {
  local pane="$1"
  local max_tries="${2:-120}" # 120 * 0.15s ~= 18s
  local i capture
  for ((i = 0; i < max_tries; i++)); do
    capture="$(tmux capture-pane -pt "$pane" -S "-30" 2>/dev/null || true)"
    if pane_looks_idle "$capture"; then
      return 0
    fi
    sleep 0.15
  done
  return 1
}

tmux_paste_and_enter() {
  local pane="$1"
  local text="$2"
  local buffer="__codex_wt_reload_${USER}_$$"

  printf '%s' "$text" | tmux load-buffer -b "$buffer" - 2>/dev/null || return 1
  tmux paste-buffer -p -b "$buffer" -t "$pane" 2>/dev/null || {
    tmux delete-buffer -b "$buffer" 2>/dev/null || true
    return 1
  }
  tmux delete-buffer -b "$buffer" 2>/dev/null || true
  tmux send-keys -t "$pane" Enter >/dev/null 2>&1 || true
  return 0
}

main() {
  require_cmd tmux || die "找不到 tmux。"
  require_cmd git || die "找不到 git。"

  local origin_pane
  origin_pane="$(resolve_origin_pane)"

  local origin_cwd
  origin_cwd="$(tmux_display "$origin_pane" "#{pane_current_path}")"
  [[ -n "${origin_cwd:-}" ]] || die "无法获取 origin pane 的工作目录。"

  local repo_root
  repo_root="$(resolve_repo_root "$origin_cwd" || true)"
  [[ -n "${repo_root:-}" ]] || die "当前目录不在 git 仓库内：${origin_cwd}"

  local branch="${1:-}"
  if [[ -z "${branch:-}" ]]; then
    if noninteractive; then
      die "用法：$(basename "$0") <branch> [follow-up]"
    fi
    local rc
    set +e
    branch="$(prompt_branch_if_needed "$repo_root")"
    rc=$?
    set -e
    if [[ "$rc" == "1" ]]; then
      die "已取消。"
    fi
    if [[ "$rc" != "0" ]]; then
      die "弹框失败（tmux-kit）。"
    fi
  fi

  local worktree_path
  worktree_path="$(existing_worktree_path_for_branch "$repo_root" "$branch" || true)"

  local wt
  wt="$(resolve_wt_script)"

  if [[ -z "${worktree_path:-}" ]]; then
    local mode="${WT_MODE:-auto}"
    local start_point="${WT_START_POINT:-}"

    if [[ "$mode" == "auto" ]]; then
      if branch_exists_local "$repo_root" "$branch"; then
        mode="add"
      else
        mode="new"
      fi
    fi

    if [[ "$mode" == "new" && -z "${start_point:-}" ]]; then
      if noninteractive; then
        die "分支不存在且未提供 WT_START_POINT；请设置 WT_START_POINT 或改用 WT_MODE=add。"
      fi
      local rc
      set +e
      start_point="$(choose_start_point_if_needed "$repo_root" "$branch")"
      rc=$?
      set -e
      if [[ "$rc" == "1" ]]; then
        die "已取消。"
      fi
      if [[ "$rc" != "0" ]]; then
        die "弹框失败（tmux-kit）。"
      fi
      if [[ "${start_point:-}" == "__HEAD__" ]]; then
        start_point=""
      fi
    fi

    if [[ "$mode" == "add" ]]; then
      "$wt" --repo "$repo_root" add "$branch" >/dev/null
    elif [[ "$mode" == "new" ]]; then
      if [[ -n "${start_point:-}" ]]; then
        "$wt" --repo "$repo_root" new "$branch" "$start_point" >/dev/null
      else
        "$wt" --repo "$repo_root" new "$branch" >/dev/null
      fi
    else
      die "WT_MODE 只支持 auto/add/new，当前：$mode"
    fi

    worktree_path="$("$wt" --repo "$repo_root" path "$branch")"
  fi

  [[ -n "${worktree_path:-}" ]] || die "无法确定 worktree 路径。"
  [[ -d "$worktree_path" ]] || die "worktree 目录不存在：$worktree_path"

  local reload_script_dir reload_script
  reload_script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  reload_script="$reload_script_dir/reload_active_codex.sh"
  [[ -x "$reload_script" ]] || die "找不到脚本：$reload_script"

  local followup="${2:-${CODEX_FOLLOWUP:-}}"
  if [[ -z "${followup:-}" ]]; then
    if noninteractive; then
      die "缺少 follow-up（第二个参数或 CODEX_FOLLOWUP）。"
    fi
    local rc
    set +e
    followup="$(prompt_followup_if_needed)"
    rc=$?
    set -e
    if [[ "$rc" == "1" ]]; then
      die "已取消。"
    fi
    if [[ "$rc" != "0" ]]; then
      die "弹框失败（tmux-kit）。"
    fi
  fi

  TARGET_CWD="$worktree_path" CODEX_RELOAD_NONINTERACTIVE=1 ORIGIN_PANE_ID="$origin_pane" "$reload_script" || die "重载 Codex 失败。"

  local session_probe
  session_probe="$(resolve_session_probe)"
  if ! wait_for_codex_session "$origin_pane" "$session_probe"; then
    die "等待 Codex 启动超时：未检测到运行中的 Codex 会话。"
  fi
  if ! wait_for_codex_prompt "$origin_pane"; then
    die "等待 Codex prompt 超时：为避免把 follow-up 误发到 shell，本次未发送。"
  fi

  tmux_paste_and_enter "$origin_pane" "$followup" || die "发送 follow-up 失败。"
  return 0
}

main "$@"
