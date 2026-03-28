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
switch_client "${target_id}"
if [[ -n "${target_name:-}" ]]; then
  switch_client "${target_name}"
fi
refresh
