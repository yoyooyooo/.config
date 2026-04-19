# .config

Personal (but shareable) XDG-style configuration snippets.

## Contents

- `tmux/`: tmux configuration (see `tmux/README.md`)
- `ghostty/`: Ghostty configuration for the cmux or Ghostty runtime on macOS (see `ghostty/README.md`)

## Quick start

- Clone this repo into `~/.config` or symlink subdirectories as needed.
- For tmux, ensure `~/.tmux.conf` contains:

  `source-file ~/.config/tmux/tmux.conf`

- For Ghostty on macOS, copy or symlink `ghostty/config.ghostty` to:

  `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`

## Language

- English: `README.md`
- 中文: `README.zh.md`
