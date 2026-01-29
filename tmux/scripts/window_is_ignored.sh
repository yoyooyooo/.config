#!/usr/bin/env bash
set -euo pipefail

window_id="${1:-}"
[[ -n "${window_id}" ]] || exit 1

# Return codes:
# - 0: ignored (noise window)
# - 1: not ignored

ignore_fg_re="${TMUX_UNREAD_IGNORE_FG_RE:-(^|[^[:alnum:]_])vite([^[:alnum:]_]|$)|(^|[^[:alnum:]_])vitepress([^[:alnum:]_]|$)|webpack-dev-server|(^|[^[:alnum:]_])webpack([^[:alnum:]_]|$)|(^|[^[:alnum:]_])next([^[:alnum:]_]|$)|(^|[^[:alnum:]_])nuxt([^[:alnum:]_]|$)|(^|[^[:alnum:]_])astro([^[:alnum:]_]|$)|(^|[^[:alnum:]_])storybook([^[:alnum:]_]|$)|(^|[^[:alnum:]_])react-scripts([^[:alnum:]_]|$)|(^|[^[:alnum:]_])craco([^[:alnum:]_]|$)|(^|[^[:alnum:]_])(pnpm|npm|yarn|bun|turbo|nx)([^[:alnum:]_]|$).*(^|[^[:alnum:]_])(dev|serve|start|develop)([^[:alnum:]_]|$)}"
[[ -n "${ignore_fg_re}" ]] || exit 1

now_s="$(date +%s 2>/dev/null || echo 0)"
if [[ -z "${now_s:-}" || ! "${now_s}" =~ ^[0-9]+$ ]]; then
  now_s=0
fi

all_ignored=1
marked_any=0
while IFS=$'\t' read -r pane_id pane_tty pane_pid pane_current_command pane_title; do
  [[ -n "${pane_id:-}" ]] || continue

  pane_ignored="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_activity 2>/dev/null || true)"
  if [[ "${pane_ignored:-0}" == "1" ]]; then
    continue
  fi

  pane_tty="${pane_tty#/dev/}"
  fg_lines=""
  all_lines=""
  if [[ -n "${pane_tty}" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      ps_raw="$(ps -t "${pane_tty}" -o state= -o command= -ww 2>/dev/null || true)"
    else
      ps_raw="$(ps -t "${pane_tty}" -o stat= -o cmd= -ww 2>/dev/null || true)"
    fi
    fg_lines="$(printf '%s\n' "${ps_raw}" | awk '$1 ~ /\+/ { $1=""; sub(/^ +/, "", $0); print }' || true)"
    all_lines="$(printf '%s\n' "${ps_raw}" | awk '{ $1=""; sub(/^ +/, "", $0); print }' || true)"
  fi

  if [[ -z "${fg_lines}" && -z "${all_lines}" ]]; then
    fg_lines="${pane_current_command} ${pane_title}"
  fi

  looks_like_shell_only=0
  if [[ -n "${all_lines}" ]]; then
    nonempty_count="$(printf '%s\n' "${all_lines}" | awk 'NF { c++ } END { print c+0 }' || echo 0)"
    if [[ -z "${nonempty_count:-}" || ! "${nonempty_count}" =~ ^[0-9]+$ ]]; then
      nonempty_count=0
    fi
    if (( nonempty_count == 1 )); then
      only_line="$(printf '%s\n' "${all_lines}" | awk 'NF { print; exit }' || true)"
      if [[ "${only_line}" =~ (^|[^[:alnum:]_])(bash|zsh|fish|sh)([^[:alnum:]_]|$) ]]; then
        looks_like_shell_only=1
      fi
    fi
  fi

  shopt -s nocasematch
  matched_ignore=0
  while IFS= read -r fg_cmd; do
    [[ -n "${fg_cmd//[[:space:]]/}" ]] || continue
    if [[ "${fg_cmd}" =~ ${ignore_fg_re} ]]; then
      matched_ignore=1
      break
    fi
  done <<<"${fg_lines}"

  if [[ "${matched_ignore}" != "1" && -n "${all_lines}" ]]; then
    while IFS= read -r fg_cmd; do
      [[ -n "${fg_cmd//[[:space:]]/}" ]] || continue
      if [[ "${fg_cmd}" =~ ${ignore_fg_re} ]]; then
        matched_ignore=1
        break
      fi
    done <<<"${all_lines}"
  fi

  if [[ "${matched_ignore}" != "1" && "${looks_like_shell_only}" == "1" && -n "${pane_pid:-}" && "${pane_pid}" =~ ^[0-9]+$ ]]; then
    ps_all="$(ps -ax -o pid= -o ppid= -o command= -ww 2>/dev/null || true)"
    if [[ -n "${ps_all}" ]]; then
      descendant_lines="$(
        printf '%s\n' "${ps_all}" | awk -v root="${pane_pid}" -v limit=60 '
          {
            pid = $1
            ppid = $2
            $1=""; $2=""
            sub(/^ +/, "", $0)
            cmd = $0
            if (pid != "") { cmd_by_pid[pid] = cmd }
            if (ppid != "" && pid != "") { children[ppid] = children[ppid] " " pid }
          }
          END {
            qh = 1
            qt = 1
            queue[1] = root
            seen[root] = 1
            emitted = 0
            while (qh <= qt && emitted < limit) {
              p = queue[qh++]
              n = split(children[p], arr, " ")
              for (i = 1; i <= n; i++) {
                c = arr[i]
                if (c == "" || (c in seen)) { continue }
                seen[c] = 1
                queue[++qt] = c
                if (c in cmd_by_pid && cmd_by_pid[c] != "") {
                  print cmd_by_pid[c]
                  emitted++
                  if (emitted >= limit) { break }
                }
              }
            }
          }
        ' || true
      )"
      if [[ -n "${descendant_lines}" ]]; then
        while IFS= read -r fg_cmd; do
          [[ -n "${fg_cmd//[[:space:]]/}" ]] || continue
          if [[ "${fg_cmd}" =~ ${ignore_fg_re} ]]; then
            matched_ignore=1
            break
          fi
        done <<<"${descendant_lines}"
      fi
    fi
  fi

  if [[ "${matched_ignore}" == "1" ]]; then
    tmux set -p -t "${pane_id}" @unread_ignore_activity 1 2>/dev/null || true
    tmux set -p -t "${pane_id}" @unread_pane_activity 0 2>/dev/null || true
    tmux set -p -t "${pane_id}" @unread_ignore_checked 1 2>/dev/null || true
    tmux set -p -t "${pane_id}" @unread_ignore_check_count "${TMUX_UNREAD_IGNORE_MAX_CHECKS:-3}" 2>/dev/null || true
    tmux set -p -t "${pane_id}" @unread_ignore_checked_at "${now_s}" 2>/dev/null || true
    marked_any=1
    continue
  fi

  all_ignored=0
  break
done < <(tmux list-panes -t "${window_id}" -F $'#{pane_id}\t#{pane_tty}\t#{pane_pid}\t#{pane_current_command}\t#{pane_title}' 2>/dev/null || true)

if [[ "${all_ignored}" == "1" ]]; then
  if [[ "${marked_any}" == "1" ]]; then
    ~/.config/tmux/scripts/sync_window_unread_activity.sh "${window_id}" >/dev/null 2>&1 || true
  fi
  exit 0
fi

exit 1
