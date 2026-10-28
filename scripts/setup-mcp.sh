#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# setup-mcp — install and enable the user-level systemd services for the MCP
# servers (kubernetes-mcp-server and mcp-grafana), and translate the OpenCode
# MCP configuration to point at them over the network instead of invoking them
# locally.
#
# Anything in the MCP configuration that points at "localhost" is translated
# to the local docker router IP (the host gateway on the default bridge
# network, e.g. 172.17.0.1) so the endpoints are reachable both from the host
# and from containers.
#
# Grafana credentials are not assumed to exist anywhere. When they are missing
# and the terminal is interactive, gum prompts for them; in non-interactive
# sessions a warning with instructions is printed instead.
#
# Usage:
#   setup-mcp                 full install-time setup (configs, units, services)
#   setup-mcp --translate-only  only rewrite the OpenCode MCP config (agent-dev)

set -uo pipefail

die()  { printf 'setup-mcp: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'setup-mcp: warning: %s\n' "$*" >&2; }
info() { printf 'setup-mcp: %s\n' "$*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
usage: setup-mcp [--translate-only]

Sets up the MCP servers (kubernetes-mcp-server, mcp-grafana) as user-level
systemd services and rewrites the OpenCode MCP config to connect to them over
the network (translating "localhost" to the docker router IP).

  --translate-only   Only rewrite the OpenCode MCP config; do not install
                     configs/units or touch the Grafana credentials.
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

K8S_PORT="8180"      # kubernetes-mcp-server (mcp/kubernetes-mcp-server.toml)
GRAFANA_PORT="8280"  # mcp-grafana
GITEA_PORT="8380"    # gitea-mcp (mcp/gitea-mcp.service)

# --- docker router detection ------------------------------------------------

# Return the IP of the host as seen from containers on the default bridge
# network (the "docker router"). Falls back to loopback when docker is absent.
docker_router_ip() {
  local ip
  ip="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  fi
  printf '%s' "${ip:-127.0.0.1}"
}

# Replace every occurrence of "localhost" in a file with the router IP.
translate_localhost() {
  local file="$1" router="$2"
  sed -i "s#localhost#${router}#g" "$file"
}

# --- systemd helpers --------------------------------------------------------

systemd_user_available() {
  has_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1
}

# --- opencode config --------------------------------------------------------

# Ensure the Grafana env file exists (consumed by the mcp-grafana unit). The
# credentials are sourced, in order, from: environment variables, an interactive
# gum prompt, and finally a warning with instructions for non-interactive
# sessions.
ensure_grafana_env() {
  local env_file="$CONFIG_DIR/mcp-grafana.env"
  local gurl="${GRAFANA_URL:-}"
  local gkey="${GRAFANA_SERVICE_ACCOUNT_TOKEN:-${GRAFANA_API_KEY:-}}"

  mkdir -p "$CONFIG_DIR"

  # Already configured: just migrate the deprecated variable name.
  if [[ -s "$env_file" ]]; then
    if grep -q '^GRAFANA_API_KEY=' "$env_file" && ! grep -q '^GRAFANA_SERVICE_ACCOUNT_TOKEN=' "$env_file"; then
      sed -i 's/^GRAFANA_API_KEY=/GRAFANA_SERVICE_ACCOUNT_TOKEN=/' "$env_file"
      info "migrated GRAFANA_API_KEY -> GRAFANA_SERVICE_ACCOUNT_TOKEN in $env_file"
    fi
    return 0
  fi

  # Interactive terminals: prompt with gum for the Grafana host and token.
  if [[ -z "$gkey" ]] && [[ -t 0 && -t 1 ]] && has_cmd gum; then
    info "Grafana MCP server requires Grafana credentials:"
    gurl="${gurl:-$(gum input --prompt "Grafana URL: " --placeholder "https://grafana.example.com")}"
    gkey="$(gum input --password --prompt "Grafana service account token: " --placeholder "glsa_...")"
  fi

  # Non-interactive (or no gum / no token entered): warn with instructions.
  if [[ -z "$gkey" ]]; then
    warn "Grafana credentials are not configured; the Grafana MCP server will not work until they are set."
    warn "  Set them by exporting (then re-running setup-mcp):"
    warn "    export GRAFANA_URL=https://grafana.example.com"
    warn "    export GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_..."
    warn "  or by writing those two lines to: $env_file"
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

# Rewrite the opencode `mcp` section to point at the network services.
translate_opencode_config() {
  local router="$1"
  local grafana_url="http://${router}:${GRAFANA_PORT}/mcp"
  local k8s_url="http://${router}:${K8S_PORT}/mcp"
  local gitea_url="http://${router}:${GITEA_PORT}/mcp"
  local tmp

  [[ -f "$OPENCODE_CONFIG" ]] || { warn "no opencode config at $OPENCODE_CONFIG; skipping"; return 0; }

  tmp="$(mktemp)"
  if has_cmd jq; then
    jq --arg g "$grafana_url" --arg k "$k8s_url" --arg t "$gitea_url" \
      '.mcp = {
         "grafana":    {"type": "remote", "url": $g, "enabled": true},
         "kubernetes": {"type": "remote", "url": $k, "enabled": true},
         "gitea":      {"type": "remote", "url": $t, "enabled": true}
       }' "$OPENCODE_CONFIG" > "$tmp" \
      && mv "$tmp" "$OPENCODE_CONFIG" \
      && info "translated $OPENCODE_CONFIG" \
      && return 0
  fi

  # python3 fallback
  if has_cmd python3; then
    G="$grafana_url" K="$k8s_url" T="$gitea_url" python3 - "$OPENCODE_CONFIG" > "$tmp" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
cfg["mcp"] = {
    "grafana": {"type": "remote", "url": os.environ["G"], "enabled": True},
    "kubernetes": {"type": "remote", "url": os.environ["K"], "enabled": True},
    "gitea": {"type": "remote", "url": os.environ["T"], "enabled": True},
}
json.dump(cfg, sys.stdout, indent=2)
PY
    rc=$?
    if [[ $rc -eq 0 ]]; then
      mv "$tmp" "$OPENCODE_CONFIG"
      info "translated $OPENCODE_CONFIG"
      return 0
    fi
  fi

  rm -f "$tmp"
  warn "jq/python3 unavailable; skipping opencode config translation"
  return 0
}

# --- main -------------------------------------------------------------------

main() {
  local translate_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --translate-only) translate_only=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  local router
  router="$(docker_router_ip)"
  has_cmd docker || warn "docker not found; assuming router IP $router"

  if [[ "$translate_only" == "1" ]]; then
    # agent-dev only needs the config rewritten before the agent container
    # mounts it; services/credentials are handled by the full install.
    translate_opencode_config "$router"
    return 0
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
  for unit in kubernetes-mcp-server mcp-grafana gitea-mcp rancher-login-watch; do
    if [[ -f "$MCP_SRC/$unit.service" ]]; then
      cp "$MCP_SRC/$unit.service" "$SYSTEMD_DIR/$unit.service"
      translate_localhost "$SYSTEMD_DIR/$unit.service" "$router"
      info "installed $SYSTEMD_DIR/$unit.service"
    else
      warn "missing $MCP_SRC/$unit.service"
    fi
  done

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

  # 4. OpenCode MCP configuration (translated).
  translate_opencode_config "$router"

  # 5. Enable and start the services (autostart with the user session).
  if systemd_user_available; then
    systemctl --user daemon-reload
    for svc in kubernetes-mcp-server mcp-grafana gitea-mcp rancher-login-watch; do
      if systemctl --user enable --now "$svc.service" 2>/dev/null; then
        info "enabled and started $svc.service"
      else
        warn "failed to enable $svc.service"
      fi
    done
  else
    warn "systemd user session unavailable; enable the units manually"
  fi
}

main "$@"
