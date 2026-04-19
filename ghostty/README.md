# ghostty

Ghostty configuration tracked for the macOS Ghostty or cmux runtime.

## Live location

- macOS: `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`

## Current behavior

- `macos-option-as-alt = true`
- `alt+arrow_right` is overridden to `\x1b[1;3C`

## Why this override exists

Ghostty defaults `alt+arrow_right` to `esc:f`. In tmux that collides with the
`M-f` zoom binding. This config keeps `M-f` for pane zoom and lets
`Alt+Right` travel as a modified right-arrow sequence instead.
