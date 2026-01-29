#!/usr/bin/env bash
# desc: fzf 选择任意 session 的 window 并切换（预览 panes + 最近输出）
# usage: 无参数（在 popup 内输入关键字过滤，回车切换）
set -euo pipefail

cleanup() {
  tmux set -gu @windows_popup_open >/dev/null 2>&1 || true
  tmux set -gu @windows_popup_client >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

pause() {
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

if ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' "fzf 未安装：请先安装 fzf（本功能依赖 fzf）。"
  pause
  exit 0
fi

raw_windows="$(tmux list-windows -a -F $'#{session_name}\t#{window_index}\t#{window_id}\t#{?#{==:#{@unread_activity},1},1,0}\t#{window_activity_flag}\t#{window_zoomed_flag}\t#{window_active}\t#{window_name}' 2>/dev/null || true)"
windows="$(
  while IFS=$'\t' read -r session_name window_index window_id custom_unread tmux_activity zoomed_flag active_flag window_name; do
    [[ -n "${session_name:-}" && -n "${window_index:-}" ]] || continue
    target="${session_name}:${window_index}"
    unread_mark=" "
    unread_flag=0
    [[ "${custom_unread:-0}" == "1" || "${tmux_activity:-0}" == "1" ]] && unread_flag=1
    if [[ "${unread_flag}" == "1" && "${custom_unread:-0}" != "1" && "${tmux_activity:-0}" == "1" ]]; then
      if ~/.config/tmux/scripts/window_is_ignored.sh "${window_id}" >/dev/null 2>&1; then
        unread_flag=0
      fi
    fi
    [[ "${unread_flag}" == "1" ]] && unread_mark="●"
    zoom_mark=" "
    [[ "${zoomed_flag:-0}" == "1" ]] && zoom_mark="⛶"
    active_mark=" "
    [[ "${active_flag:-0}" == "1" ]] && active_mark="▶"
    label="${unread_mark}${zoom_mark}${active_mark} ${session_name}:${window_index}  ${window_name}"

    # sort keys: unread first, then session name, then window index
    printf '%s\t%s\t%s\t%s\t%s\n' "${unread_flag:-0}" "$session_name" "$window_index" "$target" "$label"
  done <<<"$raw_windows" | sort -t $'\t' -k1,1nr -k2,2 -k3,3n | cut -f4-
)"
if [[ -z "${windows:-}" ]]; then
  printf '%s\n' "没有可切换的 window。"
  pause
  exit 0
fi

selected="$(
  printf '%s\n' "$windows" | fzf \
    --reverse \
    --exit-0 \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --prompt='window> ' \
    --header=$'●=未读  ⛶=zoom  ▶=该 session 当前 window' \
    --preview 'tmux list-panes -t {1} -F "#{pane_index}#{?pane_active,*, } #{pane_current_command}  #{pane_current_path}" 2>/dev/null; echo "----"; tmux capture-pane -p -t {1} -S -200 2>/dev/null | tail -n 200' \
    --preview-window='down,70%,wrap,follow' \
    --bind 'alt-w:abort'
)" || true

if [[ -z "${selected:-}" ]]; then
  exit 0
fi

target="${selected%%$'\t'*}"
if [[ -n "${target:-}" ]]; then
  tmux switch-client -t "$target"
fi
