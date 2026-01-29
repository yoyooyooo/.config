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
- `core/*.conf`: baseline (keys/hooks/ui/plugins).
- `platform/macos-iterm2.conf`: macOS+iTerm2 tweaks (auto-loaded on macOS).
- `features/init.conf`: optional feature bundles (kept small).
- `extensions/`: opt-in integrations.
- `local/`: machine-private files (ignored by default).
- `run/`: runtime/state (ignored by default).

## Extensions

### tmux-agent (optional)

Enable it by adding this to `~/.tmux.conf`:

`source-file -q ~/.config/tmux/extensions/tmux-agent/tmux.conf`

Notes:

- By default it uses `tmux-agent` from `$PATH` (`@tmux_agent_cli`).
- If you need an absolute path or extra bindings, put them in `~/.config/tmux/local/tmux-agent.conf` (not synced).

## 中文文档

- `README.zh.md`
