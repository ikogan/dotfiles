# Personal Dotfiles

```bash
./install.sh
```

Not using a dotfiles manager tool yet, this will setup:

- zsh + oh-my-zsh
- vim
- kubectl krew plugins

**Note**: The install will overwrite existing configurations without prompting.

Don't forget to setup `~/.dotfilesrc` with anything that might
change between hosts, like:

```bash
KUBERNETES_DIAGNOSTIC_IMAGE=
KUBERNETES_DIAGNOSTIC_SECRET=
SALT_GIT_ROOT_LOCATIONS=("${HOME}/Documents/Code/salt" "${HOME}/Documents/Code/some-other-place")
DOTFILES_AUTO_SWITCH_ZSH=1
```

`DOTFILES_AUTO_SWITCH_ZSH=1` makes interactive bash sessions immediately `exec zsh` when zsh is available.

`install.sh` uses `${HOME}/.tmp` for temp working directories, so it does not rely on `/tmp` being executable.

## Agentic devcontainer workflow

`agent-dev` builds a devcontainer for a workspace and opens a tmux session with
two panes — one running OpenCode, one running a shell:

```bash
agent-dev [path/to/workspace] [--config path/to/devcontainer.json] [--background] [--remove-containers]
agent-dev list
agent-dev attach [session-name]
```

`--background` (`-b`) creates the tmux session detached and exits without
attaching (it prints how to attach) — use it when running from inside another
tmux session or a non-interactive shell so it doesn't steal the current
terminal.

`--remove-containers` removes the workspace's existing terminal and OpenCode
containers before starting, so they are recreated from the freshly built image.
Use it after updating the base image: `devcontainer up` otherwise reuses the old
containers.

`agent-dev list` lists running agent sessions. `agent-dev attach` attaches to
one — with no name it presents a `gum` picker (a numbered prompt if gum isn't
installed); the name may omit the `agent-` prefix.

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
- **opencode** container (label `devcontainer.role=opencode`): mounts the host
  OpenCode config directory (`${XDG_CONFIG_HOME:-~/.config}/opencode`, as
  `OPENCODE_CONFIG_DIR`) and a **per-workspace** persistent data directory
  (`${XDG_DATA_HOME:-~/.local/share}/opencode-containers/<basename>/<path-hash>`,
  as `XDG_DATA_HOME`). Each container keeps its own SQLite DB (so sessions
  survive container recreation, but the DB is never shared with the host or
  other containers); the host's credentials are copied in with
  `opencode auth import`. The pane starts `opencode` (falls back to a shell if
  opencode is not installed in the container).

Both containers carry the `devcontainer.local_folder` and
`devcontainer.config_file` labels. The tmux layout switches automatically
between side-by-side (wide terminal: terminal on the left, OpenCode on the
right) and stacked (tall terminal: OpenCode on top, terminal on the bottom);
see `tmux-agent-layout` and the `client-resized`/`client-attached` hooks in
`dotfiles/tmux.conf.local`.

**Assumptions**: `devcontainer`, `docker`, and `tmux` must be on `PATH`. If
`opencode` isn't in the agent container, `agent-dev` copies the host's
`opencode` binary into it; SSH agent forwarding and the OpenCode config mount
rely on the devcontainer mapping the container user to the host UID (the
default).

## MCP servers

`install.sh` installs `mcp-grafana` and `kubernetes-mcp-server`, then runs
`scripts/setup-mcp.sh` (also linked to `~/.local/bin/setup-mcp`). It:

- installs user-level systemd units (`~/.config/systemd/user/`) and enables them
  to autostart with the session (when systemd is available),
- translates any `localhost` in the MCP config to the local docker router IP
  (the bridge gateway, e.g. `172.17.0.1`) so endpoints are reachable from
  containers,
- rewrites the OpenCode `mcp` section to connect to those network servers
  (`type: "remote"`) instead of invoking them locally.

Servers:

| Server | Port | Endpoint |
|--------|------|----------|
| kubernetes-mcp-server | 8180 | `http://<router>:8180/mcp` |
| mcp-grafana | 8280 | `http://<router>:8280/mcp` |

Grafana credentials (`GRAFANA_URL` / `GRAFANA_SERVICE_ACCOUNT_TOKEN`) are
written to `~/.config/mcp/mcp-grafana.env` (mode 0600). They are sourced, in
order, from environment variables, an interactive `gum` prompt, or — for
non-interactive sessions — a warning with instructions. `agent-dev` runs
`setup-mcp --translate-only` before starting containers so the OpenCode config
it mounts is always pointed at the network servers.

Note that `mcp-grafana` serves unauthenticated on a non-loopback address; see
the comment in `mcp/mcp-grafana.service` for how to require a bearer token.

The servers bind to the docker bridge gateway, so a host firewall (ufw)
blocks container access by default. If ufw is present, run
`mcp/mcp-firewall.sh` from the checkout to allow ports 8180/8280 from the
docker bridge subnet only; it is not run or linked by `install.sh`.
