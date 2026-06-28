# tmux

An XDG-style tmux configuration split into small layers, designed to be portable and easy to fork.

## Install

1. Put this directory at `~/.config/tmux` (clone or symlink).
2. Ensure `~/.tmux.conf` contains:

   ```tmux
   source-file ~/.config/tmux/tmux.conf

   # Optional: machine-local overrides (NOT synced by default)
   source-file -q ~/.config/tmux/local/private.conf

   # Optional: enable extensions
   source-file -q ~/.config/tmux/extensions/tmux-agent/tmux.conf

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
- Extended key output is configured as CSI-u in `core/base.conf` (`set -s extended-keys-format csi-u`).
- `core/*.conf`: baseline (keys/hooks/ui/plugins).
- `platform/macos-iterm2.conf`: macOS+iTerm2 tweaks (auto-loaded on macOS).
- `features/init.conf`: optional feature bundles (kept small).
- `extensions/`: opt-in integrations.
- `local/`: machine-private files (ignored by default).
- `run/`: runtime/state (ignored by default).

## Activity Switchers

`M-a`, `M-w`, and `prefix s` use `scripts/activity_rank.py` for one shared fzf order. `@agent_unread` items are shown first, normal entries are ordered by tmux activity time, and common dev-server/watch processes are demoted as background noise.

Agent runtime stash/pop: the `M-p` script panel includes `agent_runtime_stash_live.sh` to save currently live Agent runtime sessions across all reachable local tmux servers for the current user, `agent_runtime_sessions.sh` to choose a saved/recent runtime session and resume it in the triggering pane, and `agent_fork_active.sh` to fork the current pane's Agent Runtime Session. Pi sessions are recorded by the `packages/tmux-runtime-session-pi` extension in `agent-extensions` into `~/.tmux-agent/runtime-sessions/`, keyed by Agent runtime session id rather than tmux pane id, so restored tmux panes do not need to match old pane ids.

Agent progress badges are written by the tmux progress extension. Window tabs show yellow `●N` for running local agent sessions in that window and green `●N` for completed-unread local agent sessions. Session tabs use the same yellow/green counts aggregated across the whole session. These options are safe when unset.

Mouse wheel events on pane content still scroll tmux history/copy-mode, but status-line wheel events are intentionally unbound to avoid accidental window switching from trackpad scrolls. Mouse drag selection in copy-mode copies on release and stays in copy-mode instead of jumping back to live output.

Clipboard paste: `M-v`/`M-V` paste the system clipboard after dropping one trailing newline, which avoids accidental submit/control-sequence leakage in TUI apps. `C-S-v` keeps the original clipboard content.

## Extensions

### tmux-agent (optional)

Enable it by adding this to `~/.tmux.conf`:

`source-file -q ~/.config/tmux/extensions/tmux-agent/tmux.conf`

Notes:

- By default it uses `tmux-agent` from `$PATH` (`@tmux_agent_cli`).
- If you need an absolute path or extra bindings, put them in `~/.config/tmux/local/tmux-agent.conf` (not synced).

## 中文文档

- `README.zh.md`
