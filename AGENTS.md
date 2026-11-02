# Agent notes for the dotfiles repo

This repo holds personal dotfiles and setup scripts. `install.sh` symlinks them
into `$HOME` and overwrites existing configs without prompting.

## Editor work

- The editor plan lives in `TODO.md`. Read it before changing anything under
  `nvim/`, `vim/`, or the editor parts of `install.sh` and `README.md`.
- Update `TODO.md` in the same change as any editor work. Check items off only
  after they're verified, and add new decisions under "Decisions".
- `nvim/` is the main editor (Neovim 0.11+, lazy.nvim, Lua). `vim/vimrc` is a
  basic fallback with no IDE features. Don't add LSP, file trees, or git UI to it.
- Don't add keybinding-only plugins. Plugins must do real work.
- Indentation defaults: 4 spaces, 2 for YAML and Helm, tabs for Makefile and Go.
  `.editorconfig` always overrides these.

## Repo conventions

- Shell scripts use bash with `#!/bin/bash`, `has_cmd`, and the `info`/`warn`
  helpers in `install.sh`. Check them with `bash -n` and `shellcheck`.
- Missing system tools produce a `warn` message. Don't auto-install them with
  `install.sh`; they come from the system package manager.
- Lua files follow the style in `nvim/`: 4-space indent, no comments unless
  behavior isn't obvious.
