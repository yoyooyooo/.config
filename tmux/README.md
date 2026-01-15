# tmux

An XDG-style tmux configuration split into small layers, designed to be portable and easy to fork.

## Install

1. Put this directory at `~/.config/tmux` (clone or symlink).
2. Ensure `~/.tmux.conf` contains:

   ```tmux
   source-file ~/.config/tmux/tmux.conf

   # Optional: enable extensions
   source-file -q ~/.config/tmux/extensions/codex/tmux.conf

   # Optional: TPM (plugins)
   if-shell 'test -x "$HOME/.config/tmux/plugins/tpm/tpm"' 'run-shell "$HOME/.config/tmux/plugins/tpm/tpm"'
   ```

3. Optional: install TPM (Tmux Plugin Manager):

   `git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm`

4. If you use TPM, start tmux and install/update plugins:
   - Prefix is `C-a`
   - Install plugins: `prefix + F`
   - Update plugins: `prefix + D`

## Layout

- `tmux.conf`: public loader (core/platform/features).
- `~/.tmux.conf`: machine-local entry (enable extensions, run TPM, overrides).
- `core/*.conf`: baseline (keys/hooks/ui/plugins).
- `platform/macos-iterm2.conf`: macOS+iTerm2 tweaks (auto-loaded on macOS).
- `features/init.conf`: optional feature bundles (kept small).
- `extensions/`: opt-in integrations.
  - `extensions/codex/`: Codex integration (optional).
- `local/`: user-private files (ignored by default).

## macOS + iTerm2

`platform/macos-iterm2.conf` is loaded automatically on macOS. For iTerm2, it usually helps to:

- Enable “Option as Meta” if you rely on `M-*` key bindings.
- Keep “Allow Mouse Reporting” enabled if mouse behavior seems broken.

## Codex extension (optional)

Enable it by adding this to `~/.tmux.conf`:

`source-file -q ~/.config/tmux/extensions/codex/tmux.conf`

What it adds (when enabled):

- A `●` marker in window tabs for Codex “turn complete” (`@codex_done`).
- A `M-k` popup to browse Codex prompts.
- A `pane-focus-in` hook to auto-ack “turn complete” markers.
- Clicking a Codex notification will try to reveal iTerm2 hotkey window (if needed) and jump to the target tmux session/window/pane.
- `extensions/codex/scripts/panel/reload_active_codex.sh` needs Codex CLI (`codex` command; you may have an alias like `cx`).
- `extensions/codex/scripts/panel/codex_worktree_reload_followup.sh` creates/reuses a worktree, reloads Codex into that directory, then sends a follow-up (uses git-worktree-kit `wt` + tmux-kit popup when needed).

### Codex notify fan-out (dispatcher + handlers)

Codex typically allows only one notify command. This repo provides a dispatcher so you can keep your own notify script while also enabling the tmux/Codex integration.

- Dispatcher: `~/.config/tmux/extensions/codex/notify/dispatch.py`
- Built-in handler(s): `~/.config/tmux/extensions/codex/notify/handlers/*`

Environment variables (optional):

- `CODEX_CLI_BIN`: override the Codex CLI binary name/path (defaults to auto-detect `codex` then `cx`).
- `CODEX_NOTIFY_USER_HANDLER`: path to your existing notify handler (dispatcher will call it too).
- `CODEX_NOTIFY_EXTRA_HANDLER_DIRS`: extra dirs to scan for event handlers (colon-separated). For `agent-turn-complete`, name them like `codex_notify_agent_turn_complete.py` / `codex_notify_agent_turn_complete__*.sh`.
- `CODEX_NOTIFY_SUBHANDLER_TIMEOUT_SECONDS`: per-handler timeout (default `2.0`).
- `CODEX_NOTIFY_ON_CLICK_LOG_PATH`: log file for notification click-to-jump (default `~/.config/tmux/run/codex-notify-on-click.log`).
- `CODEX_NOTIFY_ON_CLICK_LOG=0`: disable click-to-jump logging.
- `CODEX_NOTIFY_ENABLE_TMUX_AUTORUN=1`: enable the `codex_notify_tmux_autorun.py` handler.

If you already use `~/.codex/notify.py`, enabling the tmux Codex extension will set `CODEX_NOTIFY_HANDLER` to the dispatcher automatically (so `~/.codex/notify.py` can delegate to it).

## 中文文档

- `README.zh.md`
