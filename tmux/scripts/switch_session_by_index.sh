#!/bin/bash

index="$1"
client="${2:-}"

if [[ -z "$index" || ! "$index" =~ ^[0-9]+$ ]]; then
  exit 0
fi

display() {
  if [[ -n "$client" ]]; then
    tmux display-message -c "$client" "$1" 2>/dev/null || true
  else
    tmux display-message "$1" 2>/dev/null || true
  fi
}

switch_client() {
  if [[ -n "$client" ]]; then
    tmux switch-client -c "$client" -t "$1" 2>/dev/null || true
  else
    tmux switch-client -t "$1" 2>/dev/null || true
  fi
}

refresh() {
  if [[ -n "$client" ]]; then
    tmux refresh-client -c "$client" -S 2>/dev/null || true
  else
    tmux refresh-client -S 2>/dev/null || true
  fi
}

# Get session matching index prefix (e.g., "1-" for index 1)
target=$(
  tmux list-sessions -F '#{session_id}::#{session_name}' 2>/dev/null | awk -F '::' -v idx="$index" '$2 ~ ("^"idx"-") {print $1 "::" $2; exit}'
)

if [[ -z "$target" ]]; then
  display "No session starts with: ${index}-"
  exit 0
fi

target_id="${target%%::*}"
target_name="${target#*::}"

first_unread_window="$(
  tmux list-windows -t "${target_id}" -F $'#{window_index}\t#{window_activity_flag}\t#{window_bell_flag}\t#{window_silence_flag}' 2>/dev/null \
    | awk -F $'\t' '$2 == 1 || $3 == 1 || $4 == 1 { print $1; exit }'
)"

target_spec_id="${target_id}"
target_spec_name="${target_name}"
if [[ -n "${first_unread_window:-}" ]]; then
  target_spec_id="${target_id}:${first_unread_window}"
  if [[ -n "${target_name:-}" ]]; then
    target_spec_name="${target_name}:${first_unread_window}"
  fi
fi

switch_client "${target_spec_id}"
if [[ -n "${target_name:-}" ]]; then
  switch_client "${target_spec_name}"
fi
refresh
