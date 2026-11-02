# Editor TODO

Living plan for the Neovim and Vim configuration. Keep this file current: check
items off as they're verified, and add new work or decisions as they come up.

## Decisions

- Neovim 0.11+ is the main editor (`nvim/`), installed via `install.sh`.
- Vim is a basic fallback (`vim/vimrc`). It has no IDE features. Its plugins are
  `copilot.vim`, `vim-polyglot`, and `editorconfig-vim`, cloned into
  `~/.vim/pack/plugins/start`.
- `install.sh` always replaces `~/.vim` and `~/.config/nvim`.
- Indentation: 4 spaces globally. YAML and Helm use 2. Makefiles and Go keep
  tabs. A project's `.editorconfig` always overrides these defaults.
- `rg` and `fzf` are system packages. `install.sh` warns when they're missing; it
  doesn't install them.
- No language servers. Diagnostics come from `nvim-lint` running installed linters on open, save, and leaving insert mode. Formatting comes from `conform.nvim`.
- Keymaps only come from plugins that do real work. Keybinding-only wrappers are
  not added.

## Neovim

### Done (written, not yet run end to end)

- [x] Config skeleton: `init.lua`, `lua/config/{options,keymaps,autocmds,filetypes,lazy}.lua`
- [x] lazy.nvim bootstrap with `lazy-lock.json` in the config directory
- [x] Colorscheme: molokai
- [x] Statusline: lualine
- [x] Buffer tabs: bufferline. `Tab`/`Shift-Tab` cycle; `Shift-t` opens a new buffer
- [x] File tree: neo-tree (`,n`), with git status. Opens automatically when the window is 120+ columns wide, and closes when it's narrower. `nvim <dir>` cds into the directory and opens the same tree. netrw is disabled, so there's one file tree. Closing the last editor window with `:q` also closes the tree and exits Neovim.
- [x] Keymap hints: which-key
- [x] Indent guides (`,ig`) and rainbow delimiters
- [x] Git signs and hunk actions: gitsigns (`]c`, `[c`, `,hp`, `,hs`, `,hr`, `,hb`, `,hd`). Clicking the gutter previews a hunk.
- [x] Git commands: vim-fugitive, loaded on `:G*` commands only
- [x] Fuzzy finder: fzf-lua (`,ff`, `,fg`, `,fb`, `,fr`, `,fh`)
- [x] Movement: flash (`s`)
- [x] Alignment: mini.align (`ga`), manual
- [x] Auto-pairs: mini.pairs. Not yet tested for overtype behavior; deferred by request
- [x] Trailing whitespace highlighting: mini.trailspace
- [x] EditorConfig: editorconfig-vim
- [x] Sessions: persistence.nvim, restores the project session when started with no arguments
- [x] Copilot ghost text: copilot.lua, `Tab` accepts (or inserts a tab when there's no suggestion). `Alt-]`/`Alt-[` cycle; `Ctrl-]` dismisses.
- [x] Completion menu: blink.cmp (path, snippets, buffer)
- [x] Automatic linting: nvim-lint runs shellcheck, ruff, luacheck, and hadolint on open, save, and leaving insert mode. Linters that aren't installed are skipped.
- [x] No LSP: language servers were dropped (pyright, bashls, yamlls, helm_ls, lua_ls, ruff server). They need project environments that containers don't have.
- [x] Treesitter (main branch): bash, gotmpl, helm, jinja, jinja_inline, lua, python, yaml, plus markdown and vim for the editor itself
- [x] Formatting on save: conform.nvim (stylua, ruff_format, shfmt with 4 spaces, yamlfmt, djlint). `,cf` formats; `:FormatToggle` toggles save-formatting
- [x] Filetype detection: `*.gotmpl`/`*.tmpl` as gotmpl, `*.j2`/`*.jinja` as jinja, Helm `templates/*.yaml|tpl` under a `Chart.yaml` project as helm
- [x] Native mappings: `,h` `,v` splits; `C-hjkl` windows; `,z` `,q` `,x` `,w` `,c` buffers; `,e` open relative to current file; `,.` lcd; `,<space>` clear search; `,sh` terminal; visual `<`/`>`/`J`/`K`; W/Q abbreviations
- [x] Removed the `,o` open-on-GitHub command (no longer wanted)
- [x] Mouse and clipboard: `mouse=a`, `clipboard=unnamedplus`
- [x] Removed: tagbar, syntastic, vimshell, ctrlp, easymotion, tabular, airline, grep.vim, command-t, vimux, salt-vim, c.vim, latex-box, javascript/css/coloresque syntax plugins, and their mappings

### Pending

- [ ] Generate `nvim/lazy-lock.json` by running `nvim` or `install.sh` once, then commit it
- [ ] Confirm the treesitter parsers install (check `:checkhealth nvim-treesitter` and `helm` availability)
- [x] Install djlint into `~/.venv` from `install.sh` (pinned to 1.49.2, on `PATH` via `shared-core.sh`)
- [ ] Install the other formatters and linters on this machine: `stylua`, `shfmt`, `yamlfmt`, `ruff`, `shellcheck`
- [ ] Sign in to Copilot in Neovim (`:Copilot auth`) and in Vim (`:Copilot setup`)
- [ ] Verify the `s` flash mapping doesn't clash with a habit. It replaces the normal-mode `s` (substitute character).
- [ ] Test mini.pairs. Deferred by request. Remove or replace it if it overtypes closing characters.
- [ ] Run `:checkhealth` after the first real launch and fix what it reports

## Vim

- [x] Replace NeoBundle config with the basic `vim/vimrc`
- [x] Remove `vim/vimrc.local` and `vim/vimrc.local.bundles`
- [x] Copilot (`copilot.vim`), syntax (`vim-polyglot`), EditorConfig (`editorconfig-vim`) cloned by `install.sh`
- [x] Verify the Vim fallback starts cleanly (checked with `vim -Nu vim/vimrc`, before `install.sh` has run)
- [ ] Verify `:Copilot setup` works

## install.sh and docs

- [x] Remove the NeoBundle install steps and the old `rm -Rf "${HOME}/.vim/*"` (which never matched anything)
- [x] Replace `~/.vim` on every run, then install the Vim plugins
- [x] Link `nvim/` to `~/.config/nvim` and sync plugins headlessly
- [x] Warn when `nvim` is missing or older than 0.11
- [x] Warn when `rg`, `fzf`, `node`, formatters, or linters are missing. Nothing is installed automatically.
- [x] Update `README.md` with the editor setup
- [x] Install tree-sitter CLI v0.27.1 from `install.sh` and the devcontainer (same version). Needs a C compiler, which `install.sh` checks for.
- [x] Create `AGENTS.md` pointing to this file
- [x] `bash -n install.sh` passes
- [ ] `shellcheck install.sh`: not run, because the `dotfiles-lint` container isn't built (run `scripts/setup-lint.sh`)
