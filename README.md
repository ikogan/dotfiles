# Personal Dotfiles

```bash
./install.sh
```

Not using a dotfiles manager tool yet, this will setup:

- zsh + oh-my-zsh
- Neovim (main editor, see [Editors](#editors))
- Vim (basic fallback)
- kubectl krew plugins
- Hyprland config (see [Hyprland](#hyprland))

**Note**: The install will overwrite existing configurations without prompting.

Don't forget to setup `~/.dotfilesrc` with anything that might
change between hosts, like:

```bash
KUBERNETES_DIAGNOSTIC_IMAGE=
KUBERNETES_DIAGNOSTIC_SECRET=
SALT_GIT_ROOT_LOCATIONS=("${HOME}/Documents/Code/salt" "${HOME}/Documents/Code/some-other-place")
DOTFILES_AUTO_SWITCH_ZSH=1
GITEA_HOST=https://git.example.com
GRAFANA_URL=https://grafana.example.com
RANCHER_URL=https://rancher.example.com
```

`GITEA_HOST` is the Gitea server for the gitea-mcp service, and `RANCHER_URL`
is what the Rancher login reminder tells you to run `rancher login` against.
Both services read `~/.dotfilesrc` themselves because systemd doesn't load the
shell config. `GRAFANA_URL` is the Grafana server for mcp-grafana; `setup-mcp`
copies it into the service's env file (see [MCP servers](#mcp-servers)).

`DOTFILES_AUTO_SWITCH_ZSH=1` makes interactive bash sessions immediately `exec zsh` when zsh is available.

`install.sh` uses `${HOME}/.tmp` for temp working directories, so it does not rely on `/tmp` being executable.

## Hyprland

`hypr/config/` replaces `~/.config/hypr/config/`. It started from the CachyOS
Hyprland + Noctalia defaults. `install.sh` only links that folder and adds one
`require("config.dotfiles")` line to `~/.config/hypr/hyprland.lua`.
`config/dotfiles.lua` loads the files the stock `hyprland.lua` doesn't. The rest
of `~/.config/hypr` (`hyprland.lua`, `hyprmon.lua`, `noctalia.lua`,
`hyprland-settings.lua`, the wallpaper) is written by HyprMon, Noctalia and the
Hyprland Settings panel, so it isn't tracked.

`stutter-watch/` is a desktop and game stutter recorder. It isn't installed by
`install.sh`; run `stutter-watch/install.sh` (add `--system` for the
`game-performance` wrapper) and `stutter-watch/uninstall.sh` to remove it. See
[stutter-watch/README.md](stutter-watch/README.md).

## Editors

- **Neovim** (`nvim/`, symlinked to `~/.config/nvim`) is the main editor. It
  needs Neovim 0.11 or newer. Plugins are managed by
  [lazy.nvim](https://github.com/folke/lazy.nvim) and pinned in
  `nvim/lazy-lock.json`. Keymap hints come from which-key: press `,` and wait
  for the menu. Progress and decisions are tracked in `TODO.md`.
- **Vim** (`vim/vimrc`, symlinked to `~/.vimrc`) is a basic fallback with syntax
  highlighting, Copilot, and EditorConfig. Its plugins are cloned into
  `~/.vim/pack/plugins/start`. `install.sh` replaces `~/.vim` on every run.

Both editors use 4-space indentation, with 2 spaces for YAML and tabs for
Makefiles and Go. A project's `.editorconfig` always overrides these defaults.

Neovim's file search and live grep need `rg` (ripgrep) and `fzf`. Copilot needs
Node.js. Treesitter parsers are built with the `tree-sitter` CLI (v0.27.1,
installed to `~/.local/bin` by `install.sh`) and a C compiler. `install.sh`
warns about any of these, plus the formatters and linters (shellcheck, ruff,
and others), that aren't on `PATH`. It installs djlint into `~/.venv`; the rest
come from your package manager.

### Neovim cheat sheet

`,` is the leader key. Press `,` and wait a moment, and **which-key** shows the
next keys you can press. Use `,f`, `,h`, `,d`, and `,c` to see their groups.

| Keys | What it does | Plugin |
|------|--------------|--------|
| `,n` | Toggle the file tree (git status shown) | neo-tree |
| `Tab` / `Shift-Tab` | Next / previous open buffer tab | bufferline |
| `Shift-t` | New empty buffer tab | built-in |
| `,c` | Close current buffer | built-in |
| `,ff` | Find files | fzf-lua |
| `,fg` | Live grep the project | fzf-lua |
| `,fb` | Pick an open buffer | fzf-lua |
| `,fr` | Recently opened files | fzf-lua |
| `,fh` | Search help | fzf-lua |
| `]c` / `[c` | Next / previous changed hunk | gitsigns |
| `,hp` | Preview the changed lines (the diff) | gitsigns |
| `,hs` / `,hr` | Stage / reset the hunk | gitsigns |
| `,hb` | Blame the current line | gitsigns |
| `,hd` | Diff the whole file against the index | gitsigns |
| Click gutter | Preview the hunk under the click | gitsigns |
| `:Git`, `:Gblame`, `:Gdiffsplit` | Git commands | vim-fugitive |
| `s` | Jump to any visible text: press `s`, type letters, press the label | flash |
| Select lines (visual), then `ga` and a delimiter such as `=` or `:` | Align text on a character | mini.align |
| `,dd` | Show the diagnostic under the cursor | nvim-lint |
| `,dl` | List diagnostics in the location list | nvim-lint |
| `]d` / `[d` | Next / previous diagnostic | built-in |
| `Tab` (insert mode) | Accept the Copilot suggestion, or insert a tab | copilot.lua |
| `Alt-]` / `Alt-[` | Next / previous Copilot suggestion | copilot.lua |
| `Ctrl-]` | Dismiss Copilot suggestion | copilot.lua |
| `,cf` | Format the buffer | conform.nvim |
| `:FormatToggle` | Turn format-on-save on or off | conform.nvim |
| `,ig` | Toggle indent guides | indent-blankline |
| `,e` | Open a file path relative to the current file | built-in |
| `,.` | Change the working directory to the current file's folder | built-in |
| `,h` / `,v` | Horizontal / vertical split | built-in |
| `Ctrl-h/j/k/l` | Move between windows | built-in |
| `,sh` | Open a terminal (`Esc Esc` leaves terminal mode) | built-in |
| `,<space>` | Clear search highlighting | built-in |
| Visual `J` / `K` | Move the selected lines down / up | built-in |

Sessions are automatic. When you start `nvim` with no file arguments, the
project's last session comes back (persistence.nvim). Opening a specific file
skips the restore.

### Other plugin notes

- **molokai:** colorscheme.
- **lualine:** statusline (branch, diff, diagnostics).
- **bufferline:** the open buffers as tabs across the top. Clicking a tab switches to it.
- **which-key:** keymap hints (see above).
- **mini.pairs:** adds closing brackets and quotes as you type. Check how it handles closers if it gets in the way.
- **mini.trailspace:** highlights trailing whitespace.
- **editorconfig-vim:** applies a project's `.editorconfig`, which overrides these defaults.
- **blink.cmp:** the completion menu for file paths, snippets, and open buffers.
- **nvim-treesitter:** syntax highlighting and parsing for the listed languages.
- **nvim-lint:** runs linters automatically when you open a file, save it, or leave insert mode. It uses shellcheck (shell), ruff (Python), luacheck (Lua), and hadolint (Dockerfile), and skips any that aren't installed. Problems show up as diagnostics, with `]d`/`[d` to jump between them.
- **rainbow-delimiters:** colors matching brackets by depth.
- **vim-fugitive:** Git commands, loaded when you run a `:G*` command.

## Agentic devcontainer workflow

`agent-dev` builds a devcontainer for a workspace and opens a tmux session with
two panes — one running a coding agent, one running a shell. `install.sh` links
it under one name per agent harness, and the name you run picks the harness:

| Command | Harness |
|---------|---------|
| `opencode-dev` | OpenCode |
| `claude-dev` | Claude Code |
| `copilot-dev` | GitHub Copilot CLI |
| `agent-dev` | asks which one, with `gum` (or a numbered prompt without it) |

Run without a terminal, `agent-dev` fails instead of asking; use one of the
named commands in scripts.

```bash
claude-dev [path/to/workspace] [--config path/to/devcontainer.json] [--background] [--remove-containers] [--kill-containers]
agent-dev list
agent-dev attach [session-name]
agent-dev reconnect [session-name]
```

`--background` (`-b`) creates the tmux session detached and exits without
attaching (it prints how to attach) — use it when running from inside another
tmux session or a non-interactive shell so it doesn't steal the current
terminal.

`--remove-containers` removes the workspace's existing terminal and agent
containers before starting, so they are recreated from the freshly built image.
Use it after updating the base image: `devcontainer up` otherwise reuses the old
containers. `--kill-containers` removes all of the workspace's containers and
exits.

Sessions are named `agent-<harness>-<workspace>`, so different harnesses can
run on the same workspace side by side (sharing its terminal container).
`list`, `attach` and `reconnect` work on sessions of every harness, whichever
name they're run as. `attach` with no name presents a `gum` picker (a numbered
prompt if gum isn't installed); the name may omit the `agent-` prefix.

The workspace defaults to the current directory and the config defaults to
`.devcontainer/devcontainer.json`. The image is built once, then two containers
are started with `devcontainer up`:

- **terminal** container (label `devcontainer.role=terminal`): mounts `${HOME}`
  at `/home/<username>` and forwards the host SSH + GPG agents by mounting
  `XDG_RUNTIME_DIR` (the gcr/gpg-agent/gnome-keyring sockets). The host
  `~/.gnupg` is mounted at the remote user's default `~/.gnupg` and `GNUPGHOME`
  is unset, so gpg finds the forwarded agent under `$XDG_RUNTIME_DIR/gnupg`.
  The host agent does the unlocking (pinentry-gnome3 via libsecret on the host);
  a custom `GNUPGHOME` would make gpg look for the agent elsewhere and fail with
  "No pinentry". The pane starts the container's shell.
- **agent** container (label `devcontainer.role=<harness>`): doesn't see the
  host home directory. It gets the host `~/.gitconfig` (read-only), the
  dotfiles' skills from `skills/` (read-only, at the harness's skills
  directory), and a **per-workspace** state directory under
  `${XDG_DATA_HOME:-~/.local/share}/<harness>-containers/<basename>/<path-hash>`,
  so sessions survive container recreation but are never shared with the host
  or other containers. The pane starts the harness (or a shell if it can't be
  installed). How each harness's host configuration gets in:

  | Harness | Config in the container | Synced from the host |
  |---------|-------------------------|----------------------|
  | OpenCode | host `~/.config/opencode` mounted as `OPENCODE_CONFIG_DIR`; state dir as `XDG_DATA_HOME` | the config is live; credentials copied with `opencode auth import`; `harness/` mounted read-only and the instructions added with `OPENCODE_CONFIG_CONTENT` |
  | Claude Code | state dir as `CLAUDE_CONFIG_DIR` | the instructions as `CLAUDE.md`; `settings.json`, `keybindings.json`, `agents/` and `commands/`; `.credentials.json` when the host's is newer; the account, onboarding and MCP server entries of `~/.claude.json`. The workspace is marked trusted. |
  | Copilot | state dir as `COPILOT_HOME` | the instructions as `copilot-instructions.md`; `settings.json`, `mcp-config.json` and `agents/` |

  Claude Code and Copilot are synced each time the agent pane starts (including
  `reconnect` and tmux splits). Copilot keeps its host token in the system
  keyring, which the container can't read, so run `/login` once inside each
  workspace's container; the token persists in its state directory.

Both containers carry the `devcontainer.local_folder` and
`devcontainer.config_file` labels. The tmux layout switches automatically
between side-by-side (wide terminal: terminal on the left, agent on the
right) and stacked (tall terminal: agent on top, terminal on the bottom);
see `tmux-agent-layout` and the `client-resized`/`client-attached` hooks in
`dotfiles/tmux.conf.local`.

**Assumptions**: `devcontainer`, `docker`, `tmux` and `jq` must be on `PATH`. If
the harness isn't in the agent container, `agent-dev` copies the host's binary
into it when it's a native executable (OpenCode, Claude Code's native install,
Copilot's standalone build), or installs `@github/copilot` with the container's
`npm`. SSH agent forwarding and the config mounts rely on the devcontainer
mapping the container user to the host UID (the default).

## Coding-agent skills and instructions

The skills in `skills/` work in OpenCode, Claude Code and Copilot CLI.
`install.sh` links each one into `~/.claude/skills/`, which Claude Code and
OpenCode both read, and into `~/.copilot/skills/` for Copilot. `agent-dev`
mounts the same folder into its agent containers.

If `harness/user-instructions.md` exists, `install.sh` links it to
`~/.claude/CLAUDE.md` (Claude Code, and OpenCode while
`~/.config/opencode/AGENTS.md` doesn't exist) and
`~/.copilot/copilot-instructions.md`. `install.sh` never replaces a real file
at either path. `agent-dev` gives its agent containers the same file; without
it, they get the host's own `CLAUDE.md` or `copilot-instructions.md`.

`harness/config.yaml` collects the settings the three tools share (skills, MCP
servers, startup timeout, and per-tool extras). Only `mcp.servers` is read so
far, by `setup-mcp`.

## MCP servers

`install.sh` installs `mcp-grafana`, `kubernetes-mcp-server`, `gitea-mcp` and,
unless the system already provides it, mikefarah's `yq` (used to read
`harness/config.yaml`; Debian and Ubuntu's `yq` package is a different tool)
into `~/.local/bin`, then runs
`scripts/setup-mcp.sh` (also linked to `~/.local/bin/setup-mcp`). It:

- installs user-level systemd units (`~/.config/systemd/user/`) and enables them
  to autostart with the session (when systemd is available),
- translates the MCP endpoints to the current docker bridge gateway (read from
  `docker0`) so the same address is reachable from both the host and containers,
- writes every server in `mcp.servers` of `harness/config.yaml` (with
  `${MCP_ROUTER}` filled in) into each installed agent harness: OpenCode v2's
  `mcp.servers` section (`type: "remote"`),
  Claude Code's user-scope servers (with `claude mcp add-json -s user`), and
  `mcpServers` in Copilot's `~/.copilot/mcp-config.json` (`type: "http"`).
  Grafana credentials from an older Copilot config that ran `mcp-grafana`
  locally are moved to `~/.config/mcp/mcp-grafana.env` first.

Servers:

| Server | Port | Endpoint |
|--------|------|----------|
| kubernetes-mcp-server | 8180 | `http://<router>:8180/mcp` |
| mcp-grafana | 8280 | `http://<router>:8280/mcp` |
| gitea-mcp | 8380 | `http://<router>:8380/mcp` |
| Atlassian (hosted) | — | `https://mcp.atlassian.com/v2/mcp` |

The Atlassian server runs on Atlassian's side, so nothing is installed for it.
Each harness signs in with OAuth on first use: run `/mcp` in Claude Code.

Grafana credentials (`GRAFANA_URL` / `GRAFANA_SERVICE_ACCOUNT_TOKEN`) are
written to `~/.config/mcp/mcp-grafana.env` (mode 0600). The URL comes from
`GRAFANA_URL` in the environment or `~/.dotfilesrc` and is copied into that
file on every `setup-mcp` run, so re-run it after changing the URL. The token
is sourced, in order, from environment variables, an interactive `gum` prompt,
or — for non-interactive sessions — a warning with instructions. `agent-dev` runs
`setup-mcp --translate-only` before starting containers so the configs it
hands the agent are always pointed at the network servers.

Note that `mcp-grafana` serves unauthenticated on a non-loopback address; see
the comment in `mcp/mcp-grafana.service` for how to require a bearer token.

The servers bind to the docker bridge gateway, so a host firewall (ufw)
blocks container access by default. If ufw is present, `install.sh` checks
for the rules that allow ports 8180/8280/8380 from the docker bridge subnets
and, if any are missing, asks for sudo to add them via `install-system.sh`.
A system unit, `docker-network-refresh.service`, refreshes UFW rules after each
Docker start or restart. A user-level `mcp-rebind.timer` also checks the bridge
gateway each minute, covering changes after login and the case where the system
unit runs before the user session exists. `setup-mcp --rebind` updates the host
and container config and restarts only MCP services whose bound address changed.
