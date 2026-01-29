#!/usr/bin/env bash
set -euo pipefail

window_id="${1:-}"
pane_id="${2:-}"

[[ -n "${pane_id}" ]] || exit 0

pane_info="$(
  tmux list-panes -a -F $'#{pane_id}\t#{window_id}\t#{session_attached}\t#{window_active}\t#{pane_active}\t#{pane_tty}\t#{pane_current_command}\t#{pane_pid}' 2>/dev/null \
    | awk -F $'\t' -v id="${pane_id}" '$1 == id { print; exit }' || true
)"
[[ -n "${pane_info}" ]] || exit 0

IFS=$'\t' read -r _pane_id detected_window_id session_attached window_active pane_active pane_tty pane_current_command pane_pid <<<"${pane_info}"

pane_unread="$(tmux show -p -t "${pane_id}" -qv @unread_pane_activity 2>/dev/null || true)"
pane_ignored="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_activity 2>/dev/null || true)"
pane_checked="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_checked 2>/dev/null || true)"
pane_check_count="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_check_count 2>/dev/null || true)"
pane_checked_at="$(tmux show -p -t "${pane_id}" -qv @unread_ignore_checked_at 2>/dev/null || true)"
if [[ "${pane_ignored:-0}" == "1" ]]; then
  exit 0
fi

if [[ -z "${window_id}" ]]; then
  window_id="${detected_window_id}"
fi

[[ -n "${window_id}" ]] || exit 0

if [[ "${session_attached:-0}" != "0" && "${window_active:-0}" == "1" && "${pane_active:-0}" == "1" ]]; then
  exit 0
fi

# Regex matched against the pane foreground command line (best-effort).
# NOTE: tmux runs this script under bash; `[[ ... =~ ... ]]` uses ERE (not PCRE),
# so avoid PCRE-only tokens like `\b`.
#
# Keep this conservative by default; customize via env var if needed.
ignore_fg_re="${TMUX_UNREAD_IGNORE_FG_RE:-(^|[^[:alnum:]_])vite([^[:alnum:]_]|$)|(^|[^[:alnum:]_])vitepress([^[:alnum:]_]|$)|webpack-dev-server|(^|[^[:alnum:]_])webpack([^[:alnum:]_]|$)|(^|[^[:alnum:]_])next([^[:alnum:]_]|$)|(^|[^[:alnum:]_])nuxt([^[:alnum:]_]|$)|(^|[^[:alnum:]_])astro([^[:alnum:]_]|$)|(^|[^[:alnum:]_])storybook([^[:alnum:]_]|$)|(^|[^[:alnum:]_])react-scripts([^[:alnum:]_]|$)|(^|[^[:alnum:]_])craco([^[:alnum:]_]|$)|(^|[^[:alnum:]_])(pnpm|npm|yarn|bun|turbo|nx)([^[:alnum:]_]|$).*(^|[^[:alnum:]_])(dev|serve|start|develop)([^[:alnum:]_]|$)}"

ignore_max_checks="${TMUX_UNREAD_IGNORE_MAX_CHECKS:-3}"
ignore_recheck_seconds="${TMUX_UNREAD_IGNORE_RECHECK_SECONDS:-5}"
if [[ -z "${ignore_max_checks}" || ! "${ignore_max_checks}" =~ ^[0-9]+$ || "${ignore_max_checks}" -le 0 ]]; then
  ignore_max_checks=3
fi
if [[ -z "${ignore_recheck_seconds}" || ! "${ignore_recheck_seconds}" =~ ^[0-9]+$ || "${ignore_recheck_seconds}" -le 0 ]]; then
  ignore_recheck_seconds=5
fi

if [[ -z "${pane_check_count:-}" || ! "${pane_check_count}" =~ ^[0-9]+$ ]]; then
  pane_check_count=0
fi
if [[ -z "${pane_checked_at:-}" || ! "${pane_checked_at}" =~ ^[0-9]+$ ]]; then
  pane_checked_at=0
fi

should_check_ignore=0
if [[ -n "${ignore_fg_re}" ]]; then
  if [[ "${pane_checked:-0}" != "1" ]]; then
    should_check_ignore=1
  elif (( pane_check_count < ignore_max_checks )); then
    now_s="$(date +%s 2>/dev/null || echo 0)"
    if [[ -z "${now_s:-}" || ! "${now_s}" =~ ^[0-9]+$ ]]; then
      now_s=0
    fi
    if (( now_s > 0 && (now_s - pane_checked_at) >= ignore_recheck_seconds )); then
      should_check_ignore=1
    fi
  fi
fi

if [[ "${should_check_ignore}" == "1" ]]; then
  now_s="${now_s:-}"
  if [[ -z "${now_s:-}" || ! "${now_s}" =~ ^[0-9]+$ || "${now_s}" -le 0 ]]; then
    now_s="$(date +%s 2>/dev/null || echo 0)"
    if [[ -z "${now_s:-}" || ! "${now_s}" =~ ^[0-9]+$ ]]; then
      now_s=0
    fi
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
  fg_lines="${pane_current_command}"
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
    # Some terminal wrappers (e.g. ones that proxy another PTY) will make the
    # pane TTY show only the shell, while the actual dev server runs in a child
    # process with a different controlling TTY. In that case, look at the pane
    # PID's descendant process tree for a best-effort match.
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
    tmux set -p -t "${pane_id}" @unread_ignore_check_count "$((pane_check_count + 1))" 2>/dev/null || true
    tmux set -p -t "${pane_id}" @unread_ignore_checked_at "${now_s:-0}" 2>/dev/null || true
    ~/.config/tmux/scripts/sync_window_unread_activity.sh "${window_id}" >/dev/null 2>&1 || true
    exit 0
  fi

  tmux set -p -t "${pane_id}" @unread_ignore_checked 1 2>/dev/null || true
  tmux set -p -t "${pane_id}" @unread_ignore_check_count "$((pane_check_count + 1))" 2>/dev/null || true
  tmux set -p -t "${pane_id}" @unread_ignore_checked_at "${now_s:-0}" 2>/dev/null || true
fi

if [[ "${pane_unread:-0}" == "1" ]]; then
  tmux set -w -t "${window_id}" @unread_activity 1 2>/dev/null || true
  exit 0
fi

tmux set -p -t "${pane_id}" @unread_pane_activity 1 2>/dev/null || true
tmux set -w -t "${window_id}" @unread_activity 1 2>/dev/null || true
