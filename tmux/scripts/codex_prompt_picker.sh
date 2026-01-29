#!/usr/bin/env bash
set -euo pipefail

# desc: fzf 选择 Codex prompts（~/.codex/prompts/*.md），右侧 bat 预览，回车后粘贴到触发的 pane
# usage: ORIGIN_PANE_ID=<pane_id> bash ~/.config/tmux/scripts/codex_prompt_picker.sh
# keys: Enter=粘贴；Esc=退出

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

last_arguments=""

if ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' "fzf 未安装：请先安装 fzf（本功能依赖 fzf）。"
  pause
  exit 0
fi

origin_pane_id="${ORIGIN_PANE_ID:-${1:-}}"
if [[ -z "${origin_pane_id:-}" ]]; then
  printf '%s\n' "缺少 ORIGIN_PANE_ID（需要从 tmux bind-key 里传入触发 pane_id）。"
  pause
  exit 0
fi

prompts_dir="${CODEX_PROMPTS_DIR:-${TMUX_CODEX_PROMPTS_DIR:-$HOME/.codex/prompts}}"
if [[ ! -d "$prompts_dir" ]]; then
  printf '%s\n' "目录不存在：$prompts_dir"
  pause
  exit 0
fi

list_md_files() {
  if command -v fd >/dev/null 2>&1; then
    fd --type f --extension md . "$prompts_dir" 2>/dev/null
    return
  fi
  find "$prompts_dir" -type f -name '*.md' -print 2>/dev/null
}

preview_script="${TMUX_CODEX_PROMPT_PREVIEW_SCRIPT:-$HOME/.config/tmux/scripts/codex_prompt_preview.sh}"
if [[ ! -x "$preview_script" ]]; then
  printf '%s\n' "缺少预览脚本：$preview_script"
  pause
  exit 0
fi

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

while true; do
  selected="$(
    list_md_files | sort | fzf \
      --reverse \
      --exit-0 \
      --prompt='prompts> ' \
      --preview "printf '%s\n\n' {}; bash \"$preview_script\" {} 2>&1" \
      --preview-window='right,55%,wrap'
  )" || true

  if [[ -z "${selected:-}" ]]; then
    exit 0
  fi

  content="$(strip_yaml_front_matter "$selected" | trim_edges)"

  if [[ "$content" == *'$ARGUMENTS'* ]]; then
    arguments="$(ask_arguments "$selected")" || continue
    last_arguments="$arguments"
    content="${content//\$ARGUMENTS/$arguments}"
    content="$(printf '%s\n' "$content" | trim_edges)"
  fi

  buffer="__codex_prompt_picker_${USER}_$$"
  printf '%s\n' "$content" | tmux load-buffer -b "$buffer" - 2>/dev/null || {
    printf '%s\n' "读取失败：$selected"
    pause
    exit 0
  }

  tmux paste-buffer -p -b "$buffer" -t "$origin_pane_id" 2>/dev/null || {
    tmux delete-buffer -b "$buffer" 2>/dev/null || true
    printf '%s\n' "粘贴失败：目标 pane 不存在或不可用（$origin_pane_id）。"
    pause
    exit 0
  }

  tmux delete-buffer -b "$buffer" 2>/dev/null || true
  exit 0
done
