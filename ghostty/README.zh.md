# ghostty

用于 macOS 上 Ghostty 或 cmux 运行时的 Ghostty 配置。

## 生效位置

- macOS：`~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`

## 当前行为

- `macos-option-as-alt = true`
- `alt+arrow_right` 被覆盖为 `\x1b[1;3C`

## 这样配置的原因

Ghostty 默认会把 `alt+arrow_right` 发成 `esc:f`。在 tmux 里这会和
`M-f` 的 pane 缩放绑定冲突。当前配置保留 `M-f` 用于 pane zoom，同时让
`Alt+Right` 以带修饰符的右箭头序列继续下传。
