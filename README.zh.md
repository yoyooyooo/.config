# .config

个人配置仓库（尽量做到可移植/可开源的 core）。

## 内容

- `tmux/`：tmux 配置（见 `tmux/README.md` / `tmux/README.zh.md`）

## 快速开始

- 把仓库放到 `~/.config`（或把子目录 symlink 到对应位置）。
- tmux 需要在 `~/.tmux.conf` 中引用：

  `source-file ~/.config/tmux/tmux.conf`

