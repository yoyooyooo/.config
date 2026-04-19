# .config

个人配置仓库（尽量做到可移植/可开源的 core）。

## 内容

- `tmux/`：tmux 配置（见 `tmux/README.md` / `tmux/README.zh.md`）
- `ghostty/`：Ghostty 配置，适用于 macOS 上的 Ghostty 或 cmux 运行时（见 `ghostty/README.md` / `ghostty/README.zh.md`）

## 快速开始

- 把仓库放到 `~/.config`（或把子目录 symlink 到对应位置）。
- tmux 需要在 `~/.tmux.conf` 中引用：

  `source-file ~/.config/tmux/tmux.conf`

- macOS 上的 Ghostty 需要把 `ghostty/config.ghostty` 复制或 symlink 到：

  `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
