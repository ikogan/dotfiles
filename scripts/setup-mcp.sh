#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# setup-mcp — install and enable the user-level systemd services for the MCP
# servers (kubernetes-mcp-server, mcp-grafana and gitea-mcp), and write the
# servers listed in harness/config.yaml (these plus any hosted ones) into the
# OpenCode, Claude Code and Copilot CLI MCP configurations.
#
# Anything in the MCP configuration that points at "localhost" is translated
# to the current docker bridge gateway so the endpoints are reachable both
# from the host and from containers. A user timer rechecks the address because
# the bridge can be recreated while the user session is already running.
#
# The Grafana URL comes from GRAFANA_URL in the environment or ~/.dotfilesrc and
# is copied into the mcp-grafana env file on every full run. The token is not
# assumed to exist anywhere. When it is missing and the terminal is
# interactive, gum prompts for it; in non-interactive sessions a warning with
# instructions is printed instead.
#
# Usage:
#   setup-mcp                 full install-time setup (configs, units, services)
#   setup-mcp --translate-only  only rewrite the agent MCP configs (agent-dev)
#   setup-mcp --rebind [--force]  re-translate to the current docker router IP
#                             and restart changed services (all with --force)

set -uo pipefail

die()  { printf 'setup-mcp: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'setup-mcp: warning: %s\n' "$*" >&2; }
info() { printf 'setup-mcp: %s\n' "$*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Print a variable's value from ~/.dotfilesrc without loading the file here.
dotfilesrc_var() {
  [[ -f "$HOME/.dotfilesrc" ]] || return 0
  # shellcheck disable=SC1091
  (. "$HOME/.dotfilesrc" >/dev/null 2>&1; printf '%s' "${!1:-}")
}

usage() {
  cat <<'EOF'
usage: setup-mcp [--translate-only | --rebind [--force]]

Sets up the MCP servers (kubernetes-mcp-server, mcp-grafana, gitea-mcp) as
user-level systemd services and rewrites the OpenCode, Claude Code and Copilot
CLI MCP configs to connect to them over the network (translating "localhost"
to the docker router IP). Harnesses that aren't installed are skipped.

  --translate-only   Only rewrite the agent MCP configs; do not install
                     configs/units or touch the Grafana credentials.
  --rebind           Re-translate configs and units to the current docker
                     router IP; restart only the services that changed.
  --force            With --rebind, restart every MCP service.
EOF
}

# Resolve the dotfiles repo root (parent of scripts/), following symlinks.
SELF="${BASH_SOURCE[0]}"
if has_cmd readlink; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MCP_SRC="$REPO_DIR/mcp"

CONFIG_DIR="$HOME/.config/mcp"
SYSTEMD_DIR="$HOME/.config/systemd/user"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
COPILOT_MCP_CONFIG="$COPILOT_DIR/mcp-config.json"
HARNESS_CONFIG="$REPO_DIR/harness/config.yaml"

K8S_PORT="8180"      # kubernetes-mcp-server (mcp/kubernetes-mcp-server.toml)
GRAFANA_PORT="8280"  # mcp-grafana
GITEA_PORT="8380"    # gitea-mcp (mcp/gitea-mcp.service)

# --- docker router detection ------------------------------------------------

# Return the IP of the host as seen from containers on the default bridge
# network (the "docker router"). Reads the docker0 interface address first,
# since `docker network inspect` can report a stale gateway. Falls back to
# loopback when docker is absent.
docker_router_ip() {
  local ip
  ip="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [[ -z "$ip" ]]; then
    ip="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | head -n1 | tr -d '[:space:]')"
  fi
  printf '%s' "${ip:-127.0.0.1}"
}

# Replace every occurrence of "localhost" in a file with the router IP.
translate_localhost() {
  local file="$1" router="$2"
  sed -i "s#localhost#${router}#g" "$file"
}

# Write SRC to DEST with "localhost" translated to the router IP. Returns 0 only
# if DEST changed.
sync_translated() {
  local src="$1" dest="$2" router="$3" tmp
  tmp="$(mktemp)"
  sed "s#localhost#${router}#g" "$src" > "$tmp"
  chmod 0644 "$tmp"
  if cmp -s "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
}

# Wait up to a minute for the docker bridge to have an address.
wait_for_docker_router() {
  local _
  for _ in $(seq 1 30); do
    [[ "$(docker_router_ip)" != "127.0.0.1" ]] && return 0
    sleep 2
  done
  return 1
}

wait_for_mcp_servers() {
  local router="$1" port ready
  for _ in {1..30}; do
    ready=1
    for port in "$K8S_PORT" "$GRAFANA_PORT" "$GITEA_PORT"; do
      # The inner bash expands positional args for its /dev/tcp redirection.
      # shellcheck disable=SC2016
      if ! timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$router" "$port" >/dev/null 2>&1; then
        ready=0
      fi
    done
    [[ "$ready" == "1" ]] && return 0
    sleep 1
  done
  return 1
}

# --- shared server list -----------------------------------------------------

# Find mikefarah/yq and store its path in YQ. Debian and Ubuntu's `yq` package
# is a different tool (kislyuk/yq) with incompatible flags. ~/.local/bin, where
# install.sh puts it, isn't on the PATH of the systemd rebind unit.
YQ=""
has_yq() {
  local candidate
  [[ -n "$YQ" ]] && return 0
  for candidate in "$(command -v yq 2>/dev/null)" "$HOME/.local/bin/yq"; do
    if [[ -x "$candidate" ]] && "$candidate" --version 2>/dev/null | grep -q 'mikefarah'; then
      YQ="$candidate"
      return 0
    fi
  done
  return 1
}

yq_missing_warning() {
  warn "mikefarah/yq is not installed, so the agent MCP configs can't be written from $HARNESS_CONFIG."
  warn "  Re-run install.sh to install it in ~/.local/bin, or: sudo pacman -S go-yq"
}

# Print the MCP servers from harness/config.yaml as a compact JSON object of
# name -> URL, with ${MCP_ROUTER} replaced by the docker router IP.
mcp_servers_json() {
  local router="$1"
  has_yq || { yq_missing_warning; return 1; }
  [[ -f "$HARNESS_CONFIG" ]] || { warn "missing $HARNESS_CONFIG"; return 1; }
  # shellcheck disable=SC2016
  MCP_ROUTER="$router" "$YQ" -o json -I 0 \
    '.mcp.servers | map_values(.url | sub("\$\{MCP_ROUTER\}", strenv(MCP_ROUTER)))' \
    "$HARNESS_CONFIG"
}

# --- systemd helpers --------------------------------------------------------

systemd_user_available() {
  has_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1
}

# --- grafana credentials ----------------------------------------------------

# Write GRAFANA_URL into the env file when it differs from what's there.
set_grafana_url() {
  local env_file="$1" gurl="$2"
  [[ -n "$gurl" ]] || return 0
  [[ "$(sed -n 's/^GRAFANA_URL=//p' "$env_file")" == "$gurl" ]] && return 0
  (
    umask 077
    { printf 'GRAFANA_URL=%s\n' "$gurl"; grep -v '^GRAFANA_URL=' "$env_file"; } > "$env_file.tmp"
  ) && mv "$env_file.tmp" "$env_file"
  info "set GRAFANA_URL=$gurl in $env_file"
}

# Ensure the Grafana env file exists (consumed by the mcp-grafana unit). The
# URL comes from GRAFANA_URL in the environment or ~/.dotfilesrc and is kept in
# sync on every run. The token is sourced, in order, from: environment
# variables, an older Copilot MCP config that ran mcp-grafana locally, an
# interactive gum prompt, and finally a warning with instructions for
# non-interactive sessions.
ensure_grafana_env() {
  local env_file="$CONFIG_DIR/mcp-grafana.env"
  local gurl="${GRAFANA_URL:-$(dotfilesrc_var GRAFANA_URL)}"
  local gkey="${GRAFANA_SERVICE_ACCOUNT_TOKEN:-${GRAFANA_API_KEY:-}}"

  mkdir -p "$CONFIG_DIR"

  # Already configured: sync the URL and migrate the deprecated variable name.
  if [[ -s "$env_file" ]]; then
    if grep -q '^GRAFANA_API_KEY=' "$env_file" && ! grep -q '^GRAFANA_SERVICE_ACCOUNT_TOKEN=' "$env_file"; then
      sed -i 's/^GRAFANA_API_KEY=/GRAFANA_SERVICE_ACCOUNT_TOKEN=/' "$env_file"
      info "migrated GRAFANA_API_KEY -> GRAFANA_SERVICE_ACCOUNT_TOKEN in $env_file"
    fi
    set_grafana_url "$env_file" "$gurl"
    return 0
  fi

  if [[ -z "$gkey" ]] && import_copilot_grafana_key "$gurl"; then
    return 0
  fi

  # Interactive terminals: prompt with gum for the Grafana host and token.
  if [[ -z "$gkey" ]] && [[ -t 0 && -t 1 ]] && has_cmd gum; then
    info "Grafana MCP server requires Grafana credentials:"
    if [[ -z "$gurl" ]]; then
      gurl="$(gum input --prompt "Grafana URL: " --placeholder "https://grafana.example.com")"
      [[ -n "$gurl" ]] && info "add GRAFANA_URL=$gurl to ~/.dotfilesrc to keep it across hosts and reinstalls"
    fi
    gkey="$(gum input --password --prompt "Grafana service account token: " --placeholder "glsa_...")"
  fi

  # Non-interactive (or no gum / no token entered): warn with instructions.
  if [[ -z "$gkey" ]]; then
    warn "Grafana credentials are not configured; the Grafana MCP server will not work until they are set."
    [[ -n "$gurl" ]] || warn "  Add GRAFANA_URL=https://grafana.example.com to ~/.dotfilesrc."
    warn "  Set the token by exporting it (then re-running setup-mcp):"
    warn "    export GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_..."
    warn "  or by writing that line to: $env_file"
    return 0
  fi

  {
    printf 'GRAFANA_URL=%s\n' "$gurl"
    printf 'GRAFANA_SERVICE_ACCOUNT_TOKEN=%s\n' "$gkey"
  } > "$env_file"
  chmod 600 "$env_file"
  info "wrote $env_file"

  [[ -n "$gurl" ]] || warn "no GRAFANA_URL set; fill it in at $env_file"
}

# --- opencode config --------------------------------------------------------

# Rewrite the OpenCode v2 `mcp.servers` section to list the shared servers.
translate_opencode_config() {
  local servers="$1"
  local tmp

  [[ -f "$OPENCODE_CONFIG" ]] || { warn "no opencode config at $OPENCODE_CONFIG; skipping"; return 0; }

  tmp="$(mktemp)"
  if has_cmd jq; then
    if ! jq --argjson s "$servers" \
      '.mcp = ((.mcp // {})
        | del(.[$s | keys[]])
        | .servers = ((.servers // {}) + ($s | map_values({"type": "remote", "url": .}))))' \
      "$OPENCODE_CONFIG" > "$tmp"; then
      rm -f "$tmp"
      warn "failed to translate $OPENCODE_CONFIG with jq"
      return 1
    fi
    if cmp -s "$tmp" "$OPENCODE_CONFIG"; then
      rm -f "$tmp"
      info "OpenCode MCP config is already current"
      return 0
    fi
    if mv "$tmp" "$OPENCODE_CONFIG"; then
      info "translated $OPENCODE_CONFIG"
      return 0
    fi
    rm -f "$tmp"
    warn "failed to update $OPENCODE_CONFIG"
    return 1
  fi

  # python3 fallback
  if has_cmd python3; then
    S="$servers" python3 - "$OPENCODE_CONFIG" > "$tmp" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
shared = json.loads(os.environ["S"])
mcp = cfg.setdefault("mcp", {})
for name in shared:
    mcp.pop(name, None)
servers = mcp.setdefault("servers", {})
servers.update({name: {"type": "remote", "url": url} for name, url in shared.items()})
json.dump(cfg, sys.stdout, indent=2)
PY
    rc=$?
    if [[ $rc -eq 0 ]]; then
      if cmp -s "$tmp" "$OPENCODE_CONFIG"; then
        rm -f "$tmp"
        info "OpenCode MCP config is already current"
        return 0
      fi
      if mv "$tmp" "$OPENCODE_CONFIG"; then
        info "translated $OPENCODE_CONFIG"
        return 0
      fi
    fi
  fi

  rm -f "$tmp"
  warn "jq/python3 unavailable; skipping opencode config translation"
  return 0
}

# --- copilot config ---------------------------------------------------------

# Copy the Grafana credentials from an older Copilot config, which ran
# mcp-grafana locally with them in its env, into the mcp-grafana env file, so
# rewriting the Copilot config doesn't lose them. Does nothing when the env file
# already has a token. A URL passed as $1 (from the environment or
# ~/.dotfilesrc) wins over the Copilot one. Returns 0 only when it wrote the
# env file.
import_copilot_grafana_key() {
  local env_file="$CONFIG_DIR/mcp-grafana.env" gurl="${1:-}" gkey
  grep -qE '^GRAFANA_SERVICE_ACCOUNT_TOKEN=.+' "$env_file" 2>/dev/null && return 1
  [[ -f "$COPILOT_MCP_CONFIG" ]] && has_cmd jq || return 1
  gkey="$(jq -r '.mcpServers.grafana.env // {} | .GRAFANA_SERVICE_ACCOUNT_TOKEN // .GRAFANA_API_KEY // empty' \
    "$COPILOT_MCP_CONFIG" 2>/dev/null)"
  [[ -n "$gkey" ]] || return 1
  gurl="${gurl:-$(jq -r '.mcpServers.grafana.env.GRAFANA_URL // empty' "$COPILOT_MCP_CONFIG" 2>/dev/null)}"
  mkdir -p "$CONFIG_DIR"
  (
    umask 077
    printf 'GRAFANA_URL=%s\nGRAFANA_SERVICE_ACCOUNT_TOKEN=%s\n' "$gurl" "$gkey" > "$env_file"
  )
  info "copied the Grafana credentials from $COPILOT_MCP_CONFIG to $env_file"
  [[ -n "$gurl" ]] || warn "no GRAFANA_URL set; fill it in at $env_file"
  return 0
}

# Rewrite the Copilot CLI `mcpServers` section to list the shared servers.
# Skipped when Copilot has never been set up on this host.
translate_copilot_config() {
  local servers="$1" tmp
  [[ -d "$COPILOT_DIR" ]] || return 0
  has_cmd jq || { warn "jq unavailable; skipping Copilot config translation"; return 0; }

  if import_copilot_grafana_key; then
    warn "restart mcp-grafana to use the copied credentials: setup-mcp --rebind --force"
  fi

  local src="$COPILOT_MCP_CONFIG"
  [[ -f "$src" ]] || src=/dev/null
  tmp="$(mktemp)"
  # -s handles a missing (empty) config: `.[0] // {}` starts from an empty one.
  if ! jq -s --argjson s "$servers" \
      '(.[0] // {}) | .mcpServers = ((.mcpServers // {})
        + ($s | map_values({"type": "http", "url": ., "tools": ["*"]})))' \
      "$src" > "$tmp"; then
    rm -f "$tmp"
    warn "failed to translate $COPILOT_MCP_CONFIG with jq"
    return 1
  fi
  if cmp -s "$tmp" "$COPILOT_MCP_CONFIG"; then
    rm -f "$tmp"
    info "Copilot MCP config is already current"
    return 0
  fi
  chmod 0600 "$tmp"
  if mv "$tmp" "$COPILOT_MCP_CONFIG"; then
    info "translated $COPILOT_MCP_CONFIG"
    return 0
  fi
  rm -f "$tmp"
  warn "failed to update $COPILOT_MCP_CONFIG"
  return 1
}

# --- claude config ----------------------------------------------------------

# Register the shared servers as user-scope Claude Code MCP servers with the
# `claude mcp` CLI, which owns ~/.claude.json. Servers already pointing at the
# right URL are left alone, so the rebind timer doesn't rewrite the file every
# minute. Skipped when Claude Code isn't installed.
translate_claude_config() {
  local servers="$1" claude_bin claude_json name url current rc=0 changed=0
  claude_bin="$(command -v claude 2>/dev/null || printf '%s' "$HOME/.local/bin/claude")"
  [[ -x "$claude_bin" ]] || return 0
  has_cmd jq || { warn "jq unavailable; skipping Claude Code config translation"; return 0; }
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    claude_json="$CLAUDE_CONFIG_DIR/.claude.json"
  else
    claude_json="$HOME/.claude.json"
  fi

  while IFS=$'\t' read -r name url; do
    current="$(jq -r --arg n "$name" '.mcpServers[$n] // {} | select(.type == "http") | .url // empty' \
      "$claude_json" 2>/dev/null)"
    [[ "$current" == "$url" ]] && continue
    "$claude_bin" mcp remove -s user "$name" >/dev/null 2>&1
    if "$claude_bin" mcp add-json -s user "$name" "{\"type\":\"http\",\"url\":\"$url\"}" >/dev/null 2>&1; then
      changed=1
    else
      warn "failed to register the $name MCP server with Claude Code"
      rc=1
    fi
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$servers")
  if [[ "$changed" == "1" ]]; then
    info "translated the Claude Code MCP servers in $claude_json"
  elif [[ "$rc" == "0" ]]; then
    info "Claude Code MCP config is already current"
  fi
  return "$rc"
}

# Point the MCP configs of every installed agent harness at the servers listed
# in harness/config.yaml.
translate_agent_configs() {
  local router="$1" servers rc=0
  servers="$(mcp_servers_json "$router")" || return 1
  translate_opencode_config "$servers" || rc=1
  translate_claude_config "$servers" || rc=1
  translate_copilot_config "$servers" || rc=1
  return "$rc"
}

# --- main -------------------------------------------------------------------

# Re-translate the MCP configs and units to the current docker router IP, and
# restart only what changed (or everything, with --force). Leaves the configs
# alone if docker never comes up.
rebind_services() {
  local force="$1" router unit svc
  local -a changed=() restart=()

  if ! wait_for_docker_router; then
    info "docker bridge is not up; leaving MCP configuration unchanged"
    return 0
  fi
  router="$(docker_router_ip)"
  mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR"

  if sync_translated "$MCP_SRC/kubernetes-mcp-server.toml" "$CONFIG_DIR/kubernetes-mcp-server.toml" "$router"; then
    restart+=(kubernetes-mcp-server)
  fi
  for unit in kubernetes-mcp-server mcp-grafana gitea-mcp rancher-login-watch; do
    if sync_translated "$MCP_SRC/$unit.service" "$SYSTEMD_DIR/$unit.service" "$router"; then
      changed+=("$unit")
    fi
  done
  restart+=("${changed[@]}")

  if [[ ${#changed[@]} -gt 0 ]]; then
    systemctl --user daemon-reload
  fi
  if [[ "$force" == "1" ]]; then
    restart=(kubernetes-mcp-server mcp-grafana gitea-mcp rancher-login-watch)
  fi

  if [[ ${#restart[@]} -gt 0 ]]; then
    for svc in "${restart[@]}"; do
      if systemctl --user restart "$svc.service"; then
        info "restarted $svc.service on $router"
      else
        warn "failed to restart $svc.service"
      fi
    done
    if ! wait_for_mcp_servers "$router"; then
      warn "MCP listeners did not all become ready on $router within 30 seconds"
    fi
  else
    info "MCP servers already bound to $router; nothing to restart"
  fi
  translate_agent_configs "$router"
}

main() {
  local translate_only=0 rebind=0 force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --translate-only) translate_only=1; shift ;;
      --rebind) rebind=1; shift ;;
      --force) force=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  if [[ "$rebind" == "1" ]]; then
    rebind_services "$force"
    return 0
  fi

  local router
  router="$(docker_router_ip)"
  has_cmd docker || warn "docker not found; assuming router IP $router"

  if [[ "$translate_only" == "1" ]]; then
    # agent-dev only needs the configs rewritten before the agent container
    # gets them; services/credentials are handled by the full install.
    translate_agent_configs "$router"
    return $?
  fi

  # Check before installing anything, so an interactive run can stop here.
  if ! has_yq; then
    yq_missing_warning
    if [[ -t 0 && -t 1 ]]; then
      local reply=y
      if has_cmd gum; then
        gum confirm --default=false "Continue without updating the agent MCP configs?" || reply=n
      else
        read -r -p "Continue without updating the agent MCP configs? [y/N] " reply
        [[ "$reply" == [yY]* ]] || reply=n
      fi
      [[ "$reply" == "n" ]] && die "install mikefarah/yq, then re-run setup-mcp"
    fi
  fi

  info "docker router: $router"
  mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR"

  # 1. Kubernetes MCP server config (translated).
  if [[ -f "$MCP_SRC/kubernetes-mcp-server.toml" ]]; then
    cp "$MCP_SRC/kubernetes-mcp-server.toml" "$CONFIG_DIR/kubernetes-mcp-server.toml"
    translate_localhost "$CONFIG_DIR/kubernetes-mcp-server.toml" "$router"
    info "installed $CONFIG_DIR/kubernetes-mcp-server.toml"
  else
    warn "missing $MCP_SRC/kubernetes-mcp-server.toml"
  fi

  # 2. Grafana environment (env vars -> existing config -> prompt -> warn).
  ensure_grafana_env

  # 3. systemd units (translated).
  local unit
  for unit in kubernetes-mcp-server mcp-grafana gitea-mcp rancher-login-watch mcp-rebind; do
    if [[ -f "$MCP_SRC/$unit.service" ]]; then
      cp "$MCP_SRC/$unit.service" "$SYSTEMD_DIR/$unit.service"
      translate_localhost "$SYSTEMD_DIR/$unit.service" "$router"
      info "installed $SYSTEMD_DIR/$unit.service"
    else
      warn "missing $MCP_SRC/$unit.service"
    fi
  done
  if [[ -f "$MCP_SRC/mcp-rebind.timer" ]]; then
    cp "$MCP_SRC/mcp-rebind.timer" "$SYSTEMD_DIR/mcp-rebind.timer"
    info "installed $SYSTEMD_DIR/mcp-rebind.timer"
  else
    warn "missing $MCP_SRC/mcp-rebind.timer"
  fi

  # 3a. gitea-mcp launcher (reads the token from the keyring; run by gitea-mcp.service).
  if [[ -f "$MCP_SRC/gitea-mcp-run.sh" ]]; then
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$MCP_SRC/gitea-mcp-run.sh" "$HOME/.local/bin/gitea-mcp-run"
    info "installed $HOME/.local/bin/gitea-mcp-run"
  else
    warn "missing $MCP_SRC/gitea-mcp-run.sh"
  fi

  # 3b. Rancher login watcher script (run by rancher-login-watch.service).
  if [[ -f "$MCP_SRC/rancher-login-watch.sh" ]]; then
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$MCP_SRC/rancher-login-watch.sh" "$HOME/.local/bin/rancher-login-watch"
    info "installed $HOME/.local/bin/rancher-login-watch"
  else
    warn "missing $MCP_SRC/rancher-login-watch.sh"
  fi

  # 4. Enable and start the services (autostart with the user session).
  if systemd_user_available; then
    systemctl --user daemon-reload
    for svc in kubernetes-mcp-server mcp-grafana gitea-mcp rancher-login-watch mcp-rebind; do
      if systemctl --user enable "$svc.service" 2>/dev/null && systemctl --user restart "$svc.service" 2>/dev/null; then
        info "enabled and started $svc.service"
      else
        warn "failed to enable $svc.service"
      fi
    done
    if systemctl --user enable mcp-rebind.timer 2>/dev/null \
      && systemctl --user restart mcp-rebind.timer 2>/dev/null; then
      info "enabled and started mcp-rebind.timer"
    else
      warn "failed to enable mcp-rebind.timer"
    fi
    if ! wait_for_mcp_servers "$router"; then
      warn "MCP listeners did not all become ready on $router within 30 seconds"
    fi
  else
    warn "systemd user session unavailable; enable the units manually"
  fi

  # Publish the endpoint URLs only after the services have had time to listen,
  # so the agents do not cache a connection-refused result during startup.
  translate_agent_configs "$router"
}

main "$@"
