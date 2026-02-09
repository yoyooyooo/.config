# tmux 配置使用说明（中文版）

本仓位对应的公共配置在 `~/.config/tmux/tmux.conf`；建议把 `~/.tmux.conf` 作为本机入口：先 `source-file ~/.config/tmux/tmux.conf`，再按需启用扩展（如 Codex）与 TPM（插件）。

> 本机相对上游的关键差异：`prefix` 改为 `C-a`；补齐了 `~/.config/tmux/scripts/toggle_scratchpad.sh`（上游配置引用但仓库缺失）。

---

## 0) 必需依赖（含 Codex 本地能力）

跨平台必需：

- `tmux`（当前验证：`tmux 3.5a`；本配置大量使用 `display-popup` / hooks / extkeys）
- `bash` >= 4（脚本使用 `mapfile` / 关联数组；macOS 需确保 `bash` 指向 Homebrew 版本）
- `git`（TPM 安装/更新插件）
- `python3`（`session_manager.py`、Codex 通知/跳转脚本等）
- `codex`（Codex CLI；官方命令名。你可自行 alias 为 `cx`；也可用 `CODEX_CLI_BIN` 覆盖脚本里调用的命令名）
- `fzf`（脚本面板、Codex prompts 浏览器、spec 预览等）
- `rg`（ripgrep；Codex prompts 浏览器全文检索）
- `bat`（文件预览渲染；建议命令名就是 `bat`）

macOS（Codex 通知/点击回跳）必需：

- iTerm2（`com.googlecode.iterm2`；用于通知点击后聚焦/定位）
- `terminal-notifier`（用于可点击通知；缺失会退化为 `osascript` 通知但不可点击回跳）
- `osascript`（系统自带；用于通知与 iTerm2 聚焦/定位）

可选增强（不影响 core 启动）：

- `fd`（更快列出 Markdown 文件；缺失会降级为 `find`）
- `rainbarf`（状态栏系统信息段；可用 `TMUX_RAINBARF=0` 关闭）
- BetterTouchTool（用于 HUD；可用 `@tmux_cross_session_btt_hud_trigger off` 关闭）

---

## 1) 记号说明

- `prefix`：`C-a`（Ctrl + A）
- `C-x`：Ctrl + x
- `M-x`：Meta + x（一般等同 `Alt+x`；macOS 里常见为 `Option+x`，需在终端里开启 “Option as Meta” 才稳定）
  - 如果 `M-*` 系列按键没反应，通常可以用 `Esc` 再按对应字母替代（例如 `Esc` `t` ≈ `M-t`）
  - 本配置把 tmux `escape-time` 设为 `80`（ms），用于让 `Esc+字母` 更稳定地被识别为 `M-字母`（也更抗 “模拟按键” 的字节间隔抖动）
  - 如果按键“偶发性失灵”，但 keyprobe 录制看到的字节是对的，优先检查 `tmux list-clients` 是否出现同一个 `tty` 绑定了多个 `tmux attach`（常见有一个 `ps` 状态是 `T`）；这会让脚本按 `client_name` 定位时落到“另一个 client”，表现为当前窗口没反应。
- `S-x`：Shift + x（大写字母）

---

## 2) 文件结构（你会经常改/用到的）

- 主配置（public loader）：`~/.config/tmux/tmux.conf`（会按顺序加载 `core/*` / `features/*` / `platform/*`）
- 入口（最小化）：`~/.tmux.conf`
- 脚本：`~/.config/tmux/scripts/`
  - `auto_cancel_copy_mode_near_bottom.sh`：copy-mode 接近底部时自动退出（避免滚轮卡住）
  - `check_and_run_on_activate.sh`：window 激活时运行项目 hook（查找 `on-tmux-window-activate.sh`）
  - `codex_notify_agent_turn_complete.py`：Codex notify 入口（纯脚本 fan-out；不依赖 tmux-agent）
  - `codex_notify_handler.py`：Codex notify handler（写 marker + 通知点击回跳；不依赖 tmux-agent）
  - `copy_to_clipboard.sh`：stdin → tmux buffer + 系统剪贴板（pbcopy/wl-copy/xclip…）
  - `iterm2_reset_and_clear_scrollback_then_attach.sh`：reset 终端 + 清 iTerm2 scrollback 后重新 attach（修复“横线残影”）
  - `keyprobe_keys.py`：按键探针（test/record 输出 JSON；排查 Option/Meta 等按键序列）
  - `kill_pane_double_tap.sh`：双击确认关闭 pane（配合 `M-x`）
  - `last_active_pane.sh`：记录/跳转上一次激活位置（跨 window/session；配合 `C-Tab`）
  - `layout_builder.sh`：两窗格布局重排（split/join/break 保持拓扑与 cwd）
  - `move_session.sh`：把当前 session 左/右移动（调用 `session_manager.py move`）
  - `move_window_to_session.sh`：把当前 window 移到指定序号的 session（调用 `session_manager.py move-window-to`）
  - `new_session.sh`：新建 session 并触发连续编号（调用 `session_manager.py ensure`）
  - `next_unread_window.sh`：跳到“下一个未读 window”（必要时跨 session；可优先 Codex done marker）
  - `record_window_seen.sh`：记录 window 最近“看过”顺序（供 `next_unread_window.sh` 做全局轮换）
  - `notify_hud_btt.py`：触发 BetterTouchTool HUD（失败则回退为系统通知）
  - `notify_macos.py`：macOS 通知助手（优先 terminal-notifier；支持 group/remove/点击动作）
  - `pane_starship_title.sh`：pane 顶部标题渲染（优先 starship；否则回退为 cmd+目录）
  - `pane_unread.sh`：pane 未读标记（mark/clear/indicator；用于 window list 的 `●`）
  - `paste_from_clipboard.sh`：系统剪贴板 → tmux buffer → paste
  - `rename_session_prompt.sh`：重命名 session（调用 `session_manager.py rename`）
  - `scripts_popup.sh`：pane 选择器 popup（fzf + 预览；支持 kill/move/swap）
  - `session_created.sh`：session-created hook（调用 `session_manager.py created`）
  - `session_manager.py`：会话编号/排序/改名/移动/窗口迁移的核心逻辑
  - `spec_preview.sh`：Spec 预览：三列联动（spec → US → task）+ 文件浏览（fzf + bat + nvim/less；tmux 内用嵌套 tmux 分屏预览更稳定）
  - `switch_session_by_index.sh`：按 `N-` 前缀切换 session（可自动跳到该 session 的首个未读 window）
  - `switch_session_relative.sh`：当前 `N-` session 的左右切换（内部调用 `switch_session_by_index.sh`）
  - `switch_to_first_unread_window.sh`：跳到当前 session 的首个未读 window
  - `tmux_btt_hud_notify.sh`：BetterTouchTool HUD 触发器（osascript；被其他脚本复用）
  - `tmux_cross_session_notify.sh`：跨 session 切换提示（优先 BTT HUD，否则 tmux message）
  - `tmux_input_method_en.sh`：进入 copy-mode 时切英文输入法（macOS；best-effort；依赖 macism 或 im-select）
  - `toggle_orientation.sh`：两窗格横/竖切换（仅限 2 panes）
  - `toggle_scratchpad.sh`：scratchpad window 开关（不存在则创建）
  - `unread_windows_count.sh`：统计 session 未读 window 数（输出 `●N`，状态栏复用）
  - `window_is_ignored.sh`：判定某个 window 是否应从“未读计数/轮转”中忽略（按前台进程命令匹配；优先看 pane 的 TTY 前台进程；若该 TTY 仅看到 shell，则扫描 `#{pane_pid}` 的子进程树做补偿；默认屏蔽 Vite/Webpack/Next/Storybook 等 Dev Server 噪音输出）
  - `update_inactive_pane_bg.sh`：多 pane 时设置 inactive pane 背景色（提升聚焦感）
  - `update_theme_color.sh`：从 `TMUX_THEME_COLOR` 更新主题色与活动边框
  - `window_auto_name.sh`：window 自动命名（优先 git branch，其次 repo 名，最后目录名）
  - `window_rename_from_path.sh`：按路径自动重命名 window（未手动改名时生效）
  - `panel/`：`M-p` 脚本面板（目录下可执行文件会自动出现在面板里）
    - `_meta_preview.sh`：面板预览：提取脚本头部 `# desc:`/`# usage:`/`# keys:` 信息
    - `clear_iterm2_ghost_lines.sh`：清理 iTerm2 “横线残影”（调用 reset+ClearScrollback+attach）
    - `launcher.sh`：面板入口（汇总 panel dirs → fzf 选择 → exec）
    - `pane_auto_layout`：递归等分当前 window 的 panes（保留分屏拓扑）
	    - `session_switcher.sh`：fzf 选择 session 并切换（带预览）
	    - `skills_codex_toggle`：skills 开关（在 `~/.codex/skills` 与 `~/.agents/skills` 间移动）
	    - `spec_preview.sh`：从 panel 启动 spec_preview（避免 popup 竞态）
	    - `window_switcher.sh`：fzf 选择任意 session 的 window 并切换（预览 panes + 输出）
- Codex 集成（tmux-agent）：`~/.config/tmux/local/codex.conf`
  - `tmux-agent codex notify`：Codex notify 入口（在 `~/.codex/config.toml` 配置）
  - `tmux-agent codex notify-ack`：pane focus 确认/清除完成标记
  - `tmux-agent codex notify-switch-done`：跨窗格切换后提示 Codex 完成（可选）
  - `tmux-agent codex prompts browse|pick`：prompts 浏览/选择
  - `tmux-agent codex copy-conversation|reload-active|worktree-reload-followup|spawn|session-info`
- tmux-agent 扩展（可选）：`~/.config/tmux/extensions/tmux-agent/tmux.conf`
  - 启用：在 `~/.tmux.conf` 里 `source-file -q ~/.config/tmux/extensions/tmux-agent/tmux.conf`
  - 本机私有：把 CLI 路径/额外绑定写到 `~/.config/tmux/local/tmux-agent.conf`（不会被同步到仓库）
- 状态栏：`~/.config/tmux/tmux-status/left.sh`、`~/.config/tmux/tmux-status/right.sh`
- 可选：`~/.config/tmux/starship-tmux.toml`（用于 pane 标题）

---

## 3) 最常用速查（先记这些就能高效用）

### 3.0 常规行为（不用背，但值得知道）

- 已开启鼠标（mouse）：可以用鼠标点选 pane、拖动分隔线；滚轮向上在有 scrollback 时才会进入/滚动 copy-mode（无 scrollback 时不进入，避免“画面置顶 + 要滚到底才退出”的体验），向下滚回底部会自动退出；切回 pane 时若离底部很近也会自动退出（避免持续输出卡住）
- 如果鼠标行为突然失效（点 pane 不切 / 滚轮不进 copy-mode）：优先检查 iTerm2 的 `View → Allow Mouse Reporting` 是否被关闭（关闭后 tmux 收不到鼠标事件）
- window/pane 编号从 0 开始（`base-index 0` / `pane-base-index 0`），并启用自动重排（`renumber-windows on`）
- window 默认会自动按当前命令重命名（`automatic-rename on`），需要固定名字时用 `prefix .` 手动改名
- 颜色：默认终端类型为 `tmux-256color`，并开启 True Color（遇到颜色异常时优先检查终端/terminfo）

### 3.1 配置

- `prefix r`：重载配置（source `~/.tmux.conf`，入口会再 `source-file ~/.config/tmux/tmux.conf`）
- `prefix F`：TPM 安装/刷新插件（首次安装/新增插件后用一次）
- `prefix D`：TPM 更新插件（输入 all 更新全部）
- `prefix C-s`：保存会话/窗口/布局（tmux-resurrect）
- `prefix C-r`：恢复会话/窗口/布局（tmux-resurrect；会二次确认；电脑重启后也可手动恢复一次）
- `prefix : cls`：清屏 + 清 tmux scrollback（copy-mode 翻不到旧输出；`clear` 在 tmux 里会歧义）
- `C-a C-a`：无 popup 时发送 literal prefix（用于嵌套 tmux 或把 `C-a` 送进程序）；有 popup 时关闭当前 popup
- `M-p`（无需 prefix）：脚本面板（fzf + popup），运行 `~/.config/tmux/scripts/panel/` 下的可执行脚本
  - 脚本描述维护在脚本头部注释：`# desc:` / `# usage:`
  - 面板会导出 `ORIGIN_PANE_ID` / `ORIGIN_CLIENT`，供脚本对“触发时的 pane/client”做操作
  - 示例：`spec_preview.sh`（在当前仓库的 `specs/<NNN-*>` 下用 fzf + bat + nvim/less 预览文件；tmux 内为分屏预览）
  - 示例：`pane_auto_layout`（对触发 pane 所在 window 做“递归等分”，保留分屏拓扑）
- `M-\`（无需 prefix）：skills 管理器（fzf + popup），仅列出含 `SKILL.md` 的目录；Enter=toggle，Ctrl-e/ Ctrl-d 启用/禁用（在 `~/.codex/skills` 与 `~/.agents/skills` 间 mv）
- `M-k`（无需 prefix）：Codex prompts 双栏浏览器（需启用 `~/.config/tmux/local/codex.conf` 且安装 `tmux-agent`），默认目录 `~/.codex/prompts`
- `M-a`（无需 prefix）：pane 选择器（fzf + popup，90% × 90%；上方列表（右侧固定窄宽快捷键提示）；下方全宽预览；`●`=该 pane 所在 window 有未读；未读优先排序），运行 `bash ~/.config/tmux/scripts/scripts_popup.sh popup_ui`（跨 session；再按一次会关闭）
- `prefix a`：同上（备用）
- `M-g`（无需 prefix）：弹出 lazygit（popup 90% × 90%，工作目录继承当前激活 pane）
- `M-/`（无需 prefix）：nvim popup 开关（启动时自动打开左侧文件树；popup 内按 `q` 可退出；再按一次会请求 nvim 退出（有未保存会提示）；若 Option 被设为 Normal，可用 `÷` 触发）

### 3.2 会话（session）

-（期望键位：session 的左右切换/换序 = window 同键位 + Shift；若按键没反应，优先排查输入法/系统快捷键是否截走修饰键。）
- `prefix ,`：重命名当前 session（只输入“标签”，最终会变成 `N-标签`）
- `prefix J` / `prefix L`：把当前 session 向左/向右移动（会触发整体重新编号）
- `prefix s`：弹出 session 选择器（fzf + popup），按预览快速切换
- `C--` / `C-+`（无需 prefix）：切到上一个 / 下一个 session（`C-=` 也等同于 `C-+`）
- `Shift+Option+[` / `Shift+Option+]`（`M-{ / M-}`；无需 prefix）：切到上一个 / 下一个 session
- `Shift+Option+-` / `Shift+Option+=`（`M-_ / M-+`；无需 prefix）：把当前 session 向左/向右移动（会触发整体重新编号）
- iTerm2 推荐兜底（不走功能键层；更稳定）：把 `Shift+Option+-/=/[/]` 映射成 `\e[112~..\e[115~`（Send Hex Codes），tmux 会识别为 `User9..User12` 并等价执行 session 切换/换序：
  - `Shift+Option+-` → Send Hex Codes: `0x1b 0x5b 0x31 0x31 0x32 0x7e`（`\e[112~`；tmux 识别为 `User9`，等价执行 session 换序 ←）
  - `Shift+Option+=` → Send Hex Codes: `0x1b 0x5b 0x31 0x31 0x33 0x7e`（`\e[113~`；tmux 识别为 `User10`，等价执行 session 换序 →）
  - `Shift+Option+[` → Send Hex Codes: `0x1b 0x5b 0x31 0x31 0x34 0x7e`（`\e[114~`；tmux 识别为 `User11`，等价执行 session 切换 ←）
  - `Shift+Option+]` → Send Hex Codes: `0x1b 0x5b 0x31 0x31 0x35 0x7e`（`\e[115~`；tmux 识别为 `User12`，等价执行 session 切换 →）
- 备注：滚轮滚动会进入 tmux 的 copy-mode；为避免 copy-mode 下“看起来坏了”，上述 session 切换/换序在 copy-mode 里也保持可用（如果你想先退出 copy-mode，可按 `q`）。
- 排查（如果突然又“没反应”）：
  - 先在 tmux 外录字节：`python3 ~/.config/tmux/scripts/keyprobe_keys.py record`（按完停 2 秒自动结束）
    - 看到 `1b 5f / 1b 2b / 1b 7b / 1b 7d`：说明 iTerm2 仍在发送 `M-_ / M-+ / M-{ / M-}`（走 Meta 路径）；通常还能用，但更容易被输入法/系统快捷键影响；建议按本节的 Send Hex 配一份兜底。
    - 看到 `1b 5b 31 31 32 7e .. 1b 5b 31 31 35 7e`：说明 iTerm2 Send Hex 已生效（`\e[112~..\e[115~`），tmux 会识别为 `User9..User12` 并触发 session 切换/换序。
- 根因总结（本次踩坑点）：
  - iTerm2 的 Key Mappings 是按“最终符号”建键位：`Shift+Option+-/=/[/]` 往往会被捕获成 `Shift+Option+_ / + / { / }`；如果只配了 `Option` 或只按 `- = [ ]` 去配，会匹配不到，导致一直透传为 `ESC + 符号`（即 `M-*`）。
  - tmux 侧脚本若不按触发的 client 取 `#{client_session}`，在多 session/多 client 时可能切到“另一个 client 的 session”，表现为“当前窗口没反应”。
- 备份（参照点；如果后续又坏了可对照/回滚）：
  - snapshot（最新）：`~/.config/tmux/backups/iterm2-tmux-keymap-swap-brackets-plusminus-20260113-095440/`（含 iTerm2 plist + tmux.conf + README + scripts）
  - tmux（最新）：`~/.config/tmux/backups/tmux.conf.bak-20260113-095440`
  - iTerm2（最新）：`~/Library/Preferences/com.googlecode.iterm2.plist.bak-20260113-095440`
  - snapshot（上一个）：`~/.config/tmux/backups/iterm2-tmux-keymap-swap-session-window-20260113-005959/`（含 iTerm2 plist + tmux.conf + scripts）
  - tmux（上一个）：`~/.config/tmux/backups/tmux.conf.bak-20260113-005959`
  - iTerm2（上一个）：`~/Library/Preferences/com.googlecode.iterm2.plist.bak-20260113-005959`
  - snapshot（更早）：`~/.config/tmux/backups/iterm2-tmux-session-keymap-20260113-002824/`
  - tmux（更早）：`~/.config/tmux/backups/tmux.conf.bak-20260113-002824`
  - iTerm2（更早）：`~/Library/Preferences/com.googlecode.iterm2.plist.bak-20260113-002824`
  - 恢复：
    - tmux：`cp ~/.config/tmux/backups/tmux.conf.bak-20260113-095440 ~/.config/tmux/tmux.conf` 后执行 `tmux source-file ~/.tmux.conf`
    - iTerm2：`cp ~/Library/Preferences/com.googlecode.iterm2.plist.bak-20260113-095440 ~/Library/Preferences/com.googlecode.iterm2.plist` 后 `Cmd+Q` 彻底退出 iTerm2 并重开
- `C-1..C-9`（无需 prefix）：切到编号为 1..9 的 session（按 session 名字前缀 `^N-` 匹配）
- 切换 session（含鼠标点状态栏 session tabs）时：若目标 session 有未读 window，会自动跳到该 session 的第一个未读 window；无未读则保持默认落点
- 如果 `C-1..C-9` 在 iTerm2 里按了没反应（用 `python3 ~/.config/tmux/scripts/keyprobe_keys.py record` 测到的仍是普通字符 `1/2/...`），在 iTerm2 里把 `C-1..C-9` 映射为 `S-F1..S-F9` 的序列：
  - `C-1` → `0x1b 0x5b 0x31 0x3b 0x32 0x50`（`\e[1;2P`）
  - `C-2` → `0x1b 0x5b 0x31 0x3b 0x32 0x51`（`\e[1;2Q`）
  - `C-3` → `0x1b 0x5b 0x31 0x3b 0x32 0x52`（`\e[1;2R`）
  - `C-4` → `0x1b 0x5b 0x31 0x3b 0x32 0x53`（`\e[1;2S`）
  - `C-5` → `0x1b 0x5b 0x31 0x35 0x3b 0x32 0x7e`（`\e[15;2~`）
  - `C-6` → `0x1b 0x5b 0x31 0x37 0x3b 0x32 0x7e`（`\e[17;2~`）
  - `C-7` → `0x1b 0x5b 0x31 0x38 0x3b 0x32 0x7e`（`\e[18;2~`）
  - `C-8` → `0x1b 0x5b 0x31 0x39 0x3b 0x32 0x7e`（`\e[19;2~`）
  - `C-9` → `0x1b 0x5b 0x32 0x30 0x3b 0x32 0x7e`（`\e[20;2~`）
- `F1..F5`（无需 prefix）：同上（1..5）
- `Shift+Option+X`（`M-X`；无需 prefix）：关闭当前 session（`y/n` 二次确认）
- 新建 session：
  - `prefix C-c`：tmux 原生命令 `new-session`
  - `M-S`：用脚本新建并切换（`~/.config/tmux/scripts/new_session.sh`，并自动编号）

### 3.3 窗口（window）

- `M-n`（无需 prefix）：新建 window（工作目录继承当前 pane）
- `M-w`（无需 prefix）：弹出 window 选择器（fzf + popup，跨 session；`●`=未读；未读优先排序；再按一次会关闭）
- `Option+[` / `Option+]`（`M-[ / M-]`；无需 prefix）：上一个 / 下一个 window
- `Option+-` / `Option+=`（`M-- / M-=`；无需 prefix）：交换当前 window 与前/后 window（`swap-window`）
  - 备用：`Option+u/o`（`M-u / M-o`）同上（更不容易被输入法吞）
- iTerm2 可选兜底（不走功能键层）：把 Option 组合映射成 `\e[100~`/`\e[101~`/`\e[110~`/`\e[111~`（Send Hex Codes），tmux 会识别为 `User1/2/7/8` 并等价执行：
  - `Option+[` → Send Hex Codes: `0x1b 0x5b 0x31 0x30 0x30 0x7e`（`\e[100~`；tmux 识别为 `User1`，等价执行 window 切换 ←）
  - `Option+]` → Send Hex Codes: `0x1b 0x5b 0x31 0x30 0x31 0x7e`（`\e[101~`；tmux 识别为 `User2`，等价执行 window 切换 →）
  - `Option+-` → Send Hex Codes: `0x1b 0x5b 0x31 0x31 0x30 0x7e`（`\e[110~`；tmux 识别为 `User7`，等价执行 window 换序 ←）
  - `Option+=` → Send Hex Codes: `0x1b 0x5b 0x31 0x31 0x31 0x7e`（`\e[111~`；tmux 识别为 `User8`，等价执行 window 换序 →）
- 备注：如果你用 BetterTouchTool/Keyboard Maestro 等“模拟按键”，触发后变成输入 `—`/`±`（而不是切换/换序 window），说明它走的是“输入字符”的路径，绕过了 iTerm2 的 Meta/Send Hex；建议直接让自动化工具发送 `F6/F7`（切换）+ `F8/F9`（换序）（最稳）来控制 window。
- 备注：滚轮滚动会进入 tmux 的 copy-mode；为避免 copy-mode 下“看起来坏了”，tmux 也在 copy-mode 里绑定了 `F6/F7/F8/F9` 等价执行（如果你想先退出 copy-mode，可按 `q`）。
- `M-Tab`（无需 prefix）：在所有 session 的“未读 window”里轮流切换（按最近访问做 LRU，把刚切过的放到队尾）
  - 优先级：Codex `agent-turn-complete` marker → 全局未读 window（LRU）
  - 可选：如需先在当前 window 内跳到未读 pane，可 `tmux set -g @next_unread_prioritize_current_panes 1`（默认关闭，避免某些持续输出 pane 导致 M-Tab “卡在当前 window”）
  - “未读 window”来源：自定义 `@unread_activity`（`pipe-pane` 监听 pane 输出写入）或 tmux 内置 `window_activity_flag/window_bell_flag/window_silence_flag`
  - 噪音过滤：当仅因 `window_activity_flag` 触发时，按前台进程命令匹配忽略（优先看 pane 的 TTY 前台进程；若该 TTY 仅看到 shell，则扫描 `#{pane_pid}` 的子进程树；默认覆盖 Vite/Webpack/Next/Storybook 等 Dev Server；可用 `TMUX_UNREAD_IGNORE_FG_RE` 调整）
  - 默认忽略 session 名称包含“后台”的会话（可用 `TMUX_NEXT_UNREAD_EXCLUDE_SESSION_SUBSTR` 调整；支持逗号分隔多个子串；置空关闭）
  - 可用 `TMUX_NEXT_UNREAD_PRIORITIZE_CODEX_DONE=0` 关闭 Codex done 优先级
  - 排错：`tmux set -g @next_unread_debug 1` 开启调试日志（写入 `~/.config/tmux/run/next-unread/debug.*.log`）；关闭：`tmux set -gu @next_unread_debug`
  - 可选显眼提示：如果你在 BetterTouchTool 里建了 Named Trigger `btt-hud-overlay`（动作：Show HUD Overlay；文案：`{hud_title}` + `{hud_body}`），跨 session 跳转时会触发 HUD；默认会尽量避免用 tmux message 覆盖 window list
    - 强制显示 tmux message：`tmux set -g @tmux_cross_session_show_tmux_message on`
    - 调整 tmux message 时长（ms）：`tmux set -g @tmux_cross_session_tmux_message_delay_ms 800`
    - 关闭 HUD 尝试：`tmux set -g @tmux_cross_session_btt_hud_trigger off`
- `M-1..M-9`（无需 prefix）：跳转到 window 1..9
- `prefix .`：重命名 window
- `prefix C-p` / `prefix C-n`：上一个/下一个 window

### 3.4 窗格（pane）

- 分屏（需要 prefix；方向键位是 `i/k/j/l` = 上/下/左/右）：
  - `prefix j`：向左分屏（新 pane 在左侧）
  - `prefix l`：向右分屏（智能布局：1+2+2 → 1+3+3；最多 7 panes）
  - `prefix i`：向上分屏
  - `prefix k`：向下分屏
- 分屏后会自动把当前 window 的 panes “等分”（等价于 `select-layout -E`）
- 关闭 pane 后也会自动等分（等价于 `select-layout -E`）；支持“先上下再左右”这种混合分屏（zoom 时不触发）
- 切换 pane（无需 prefix）：`M-i`/`M-Down`/`M-j`/`M-l`（上/下/左/右）
- 回到上一次激活位置（跨 window/session；无需 prefix）：`C-Tab`（可在两个位置间来回切换；window 内等价 `prefix ;`）
- 缩放当前 pane（无需 prefix）：`M-f`（zoom；缩放时窗口名会出现 `⛶`，pane 顶部边框会红底显示 `⛶ ZOOM`）
- 缩放当前 pane（无需 prefix）：`Shift+Cmd+Enter`（同上；需在 iTerm2 把该按键映射为发送 `\e[99~`）
- 关闭当前 pane（无需 prefix）：`M-x`（连按两次确认；iTerm2 兼容键：`≈`）
- 关闭当前 pane（需要 prefix）：`prefix x` 后按 `x` 确认、按 `n` 取消（所以可 `prefix x x` 关闭）
- 设置当前 pane 标题（需要 prefix）：`prefix /`（等价于 `select-pane -T`；建议用于让 pane 顶部标签 / `M-a` 列表更好识别；`prefix T` 仍可用；原 `prefix /` 的“查按键绑定”移到 `prefix K`）
- 调整 pane 大小（无需 prefix；大写=Shift）：`M-I/K/J/L`（上/下/左/右，每次 3 格）
  - iTerm2 推荐兜底（更稳定）：把 `Shift+Option+I/J/K/L` 映射为 `\e[102~`/`\e[103~`/`\e[104~`/`\e[105~`，由 tmux 的 `User3..User6` 捕获执行 resize。
    - iTerm2：Profiles → Keys → Key Mappings
      - Shift+Option+I → Send Hex Codes: `0x1b 0x5b 0x31 0x30 0x32 0x7e`
      - Shift+Option+J → Send Hex Codes: `0x1b 0x5b 0x31 0x30 0x33 0x7e`
      - Shift+Option+K → Send Hex Codes: `0x1b 0x5b 0x31 0x30 0x34 0x7e`
      - Shift+Option+L → Send Hex Codes: `0x1b 0x5b 0x31 0x30 0x35 0x7e`
  - 兜底（需要 prefix）：`prefix Shift+↑/↓/←/→`（每次 3 格）
  - 排查：在 tmux pane 里跑 `python3 ~/.config/tmux/scripts/keyprobe_keys.py`（逐项 test）或 `python3 ~/.config/tmux/scripts/keyprobe_keys.py record`（通用录制；Ctrl-C 结束；日志默认写入 `~/.config/tmux/run/keyprobe_record_*.json`）；如果看到仍在输出 `1b 49` 这类 `Esc+字母`，说明键还在“透传到 pane”，tmux 没吃到。
- 两窗格方向切换（需要 prefix）：`prefix Space`（左右/上下/平铺，仅限 2 panes）
- 同步输入（需要 prefix）：`prefix C-g`（开/关 `synchronize-panes`，适合多窗格同时跑同一命令）

### 3.5 系统剪贴板

- 粘贴系统剪贴板（无需 prefix）：
  - `C-S-v`：调用 `~/.config/tmux/scripts/paste_from_clipboard.sh`
  - `M-V`：同上（更通用，推荐优先用这个）
- 进入 copy-mode（无需 prefix）：`M-v`
- copy-mode 里用鼠标滚轮向下滚回到底部会自动退出 copy-mode（回到实时输出）
- 如果 pane 停在 copy-mode 且离底部不远，切换到该 pane 会自动退出（阈值：`tmux set -g @copy_mode_auto_cancel_threshold 20`）
- copy-mode（vi）里搜索：`/` 向下、`?` 向上；跳转匹配：`n` 下一处、`p` 上一处（也可用 `=`/`-`）
- copy-mode（vi）里复制到系统剪贴板：按 `y`（调用 `~/.config/tmux/scripts/copy_to_clipboard.sh`）
- tmux buffer（需要 prefix）：`prefix b` 列出 buffers；`prefix p` 粘贴当前 buffer

### 3.6 Scratchpad

- `M-s`（无需 prefix）：切换 scratchpad window（默认名字 `scratchpad`）

---

## 4) 会话编号体系（N-标签）怎么工作

这套配置把 session 当成“项目/上下文”容器，并强制使用 `N-标签` 的命名规范（例如 `1-imd`、`2-notes`）。

- 触发点
  - tmux 启动时会主动执行一次 `~/.config/tmux/scripts/session_created.sh`
  - 每次新建 session 也会触发 `session-created` hook，再跑一次同样逻辑
- 行为
  - `session_manager.py ensure/created` 会把所有 session 按顺序重命名为 `1-.../2-...`
  - 你在 `prefix ,` 里输入的是“标签”，脚本会保留标签并重新编号
- 影响
  - 优点：`C-1..C-9` 这种切换非常顺手；编号稳定、可重排
  - 注意：如果你依赖“固定 session 名称”做脚本/自动化，这套会重命名它（需要适配）

---

## 5) Window / Pane 的高级操作

### 5.1 Pane ↔ Window 的转换

- `M-O`（无需 prefix）：`break-pane` 把当前 pane 拆成一个新 window
- `M-!/@/#/$/%/^/&/*/(`（无需 prefix）：`join-pane` 把当前 pane 移入 window 1..9
  - 这些符号对应数字 1..9（Shift+数字）

### 5.2 把当前 window 移到某个 session（需要 prefix）

这依赖 `session_manager.py` 的排序（也就是你看到的 `1-.../2-...` 顺序）：

- `prefix 1..9`：把当前 window 移到 session #1..#9
- `prefix 0`：把当前 window 移到 session #10

### 5.3 交换 pane

- `prefix >`：与“下一个 pane”交换（`swap-pane -D`）
- `prefix <`：与“上一个 pane”交换（`swap-pane -U`）
- `prefix |`：执行 `swap-pane`（tmux 原生命令；更偏手动/高级用法）

### 5.4 两窗格布局“定向重排”（需要 prefix）

当你只有 2 panes 时，可以把它们重排成你想要的方向：

- `prefix I`：把右侧设为新 pane（`layout_builder.sh right`）
- `prefix N`：把左侧设为新 pane
- `prefix U`：把上方设为新 pane
- `prefix e`：把下方设为新 pane

### 5.5 Tree 视图（挑 window/pane / 移动 pane）

- `prefix W`：打开 `choose-tree`（带缩放）
- `prefix S`：打开 tree 并把选中的 pane “纵向移入”当前 window（`move-pane -v`）
- `prefix V`：打开 tree 并把选中的 pane “横向移入”当前 window（`move-pane -h`）

---

## 6) Copy-mode（vi）细节

进入：`M-v`（无需 prefix）。

常用键位（仅在 copy-mode-vi 表里生效）：

- 光标移动：`i/k/j/l`（上/下/左/右）
- 选择：`v` 开始选择；`C-v` 矩形选择
- 复制并退出：`y`（复制到 tmux buffer + 系统剪贴板）
- 滚动：`C-u` 向上 5 行；`C-e` 向下 5 行

> 小提示：很多终端对 `C-S-v` 支持不稳定，因此“粘贴系统剪贴板”更推荐用 `M-V`。

---

## 7) Scratchpad（`M-s`）说明

`~/.config/tmux/scripts/toggle_scratchpad.sh` 的行为是：

- 当前 session 内如果存在名为 `scratchpad` 的 window：
  - 当前不在 scratchpad：切到该 window
  - 当前就在 scratchpad：切回 `last-window`
- 不存在：在当前 session 新建一个名为 `scratchpad` 的 window

可通过环境变量自定义名字：

- `TMUX_SCRATCH_WINDOW_NAME=scratchpad`

---

## 8) scripts_popup：跨 pane 的 fzf 工具（可选）

文件：`~/.config/tmux/scripts/scripts_popup.sh`

这不是默认按键触发的功能，但已经被 hook 用来维护“最近使用 pane 列表”（MRU）。你可以手动运行：

```bash
bash ~/.config/tmux/scripts/scripts_popup.sh new_window
```

它会开一个新 window 跑 fzf，支持：

- 多选 pane、预览内容、快速跳转
- 常用 fzf 内按键（来自脚本内 `--bind`）：
  - `Alt-p`：开关预览
  - `Ctrl-r`：刷新列表
  - `Ctrl-x`：杀掉选中的 pane
  - `Ctrl-v`：把选中 pane 横向 move 到“最近 pane”
  - `Ctrl-s`：把选中 pane 纵向 move 到“最近 pane”
  - `Ctrl-t`：与“最近 pane”交换

依赖：`fzf`（没有的话脚本会直接退出）。

---

## 9) 主题与状态栏（为什么看起来是这样的）

### 9.1 主题色（`TMUX_THEME_COLOR`）

这套配置把主题色作为环境变量透传，并在加载时执行：

- `~/.config/tmux/scripts/update_theme_color.sh`

你可以这样临时改色（当前 server 生效）：

```bash
tmux set-environment -g TMUX_THEME_COLOR '#b294bb'
~/.config/tmux/scripts/update_theme_color.sh
tmux refresh-client -S
```

### 9.2 Pane 顶部边框标题（Starship，可选）

`pane-border-format` 会调用：

- `~/.config/tmux/scripts/pane_starship_title.sh`

有 `starship` 时，它会用 `~/.config/tmux/starship-tmux.toml` 渲染标题；没有则降级为 `命令 — 目录名`。

### 9.3 状态栏 left / right

- 状态栏第 1 行：session tabs 各 session 标题左侧显示计数标记：黄色 `●N`=该 session 未读 window 数（`@unread_activity` + tmux `window_activity_flag/window_bell_flag/window_silence_flag`；仅因 `window_activity_flag` 触发的噪音 window 会按前台进程规则过滤）
- window tabs（底部）：提示圆点 `●`：绿色=Codex 完成未确认（`@codex_done=1`）；黄色=未读（`@unread_activity=1`）；当前 window 不显示圆点。`pipe-pane` 监听 pane 输出写入；另外当 window 因 tmux `activity/bell/silence` 被计入未读时也会镜像写入 `@unread_activity` 以保证显示一致；噪音 pane 命中后会缓存 `@unread_ignore_activity=1`（粘性，避免每次输出都做 `ps` 检测），如需重新判定可手动清除：`tmux set -p -t %123 -u @unread_ignore_activity -u @unread_ignore_checked -u @unread_ignore_check_count -u @unread_ignore_checked_at`（可用 `TMUX_UNREAD_IGNORE_FG_RE` / `TMUX_UNREAD_IGNORE_MAX_CHECKS` / `TMUX_UNREAD_IGNORE_RECHECK_SECONDS` 调整）；索引与标题之间用 pane 数标记替代冒号（1-8：`·⠆⠖⠶⡶⡷⣷⣿`，超过 8 仍显示 `⣿`）

- Left：`~/.config/tmux/tmux-status/left.sh`
  - 高亮当前 session；窄屏时会自动精简显示
  - 鼠标左键点击某个 session 标签可直接切换（与 window tabs 一致）
  - 可调：`TMUX_LEFT_NARROW_WIDTH`（低于该宽度走窄屏策略）
- Right：`~/.config/tmux/tmux-status/right.sh`
  - 若安装 `rainbarf` 则显示系统信息段
  - 可调：`TMUX_RIGHT_MIN_WIDTH`（小于该宽度直接隐藏右侧）
  - 可关：`TMUX_RAINBARF=0`

---

## 10) 项目激活 hook：切 window 时自动跑项目脚本

配置在 `after-select-window` hook：每次切换 window，会执行：

- `~/.config/tmux/scripts/check_and_run_on_activate.sh "#{pane_current_path}"`

它会按顺序查找并执行（要求可执行 `chmod +x`）：

1. 当前目录：`./on-tmux-window-activate.sh`
2. 父目录：`../on-tmux-window-activate.sh`

典型用途：进入项目时自动设置环境、打印提示、启动/恢复 watcher（注意别写会卡住 tmux 的脚本）。

---
## 11) 常见问题

### 11.1 `M-*` 系列快捷键没反应

- 先试 `Esc` 再按字母（例如 `Esc` `t`）
- macOS 终端需要把 Option 当作 Meta 发送（iTerm2/WezTerm/Kitty 等都有对应设置）
