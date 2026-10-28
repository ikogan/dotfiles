#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# mcp-firewall — open the MCP server ports to the docker bridge network only.
#
# Uses ufw (when present) to allow inbound TCP to the MCP servers
# (kubernetes-mcp-server on 8180, mcp-grafana on 8280) exclusively from the
# default docker bridge subnet (e.g. 172.17.0.0/16), so containers can reach the
# host's MCP servers while all other sources stay denied.
#
# This is intentionally NOT run or linked by install.sh — review it and run it
# explicitly from the checkout:
#
#   ./mcp/mcp-firewall.sh

set -uo pipefail

die()  { printf 'mcp-firewall: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'mcp-firewall: warning: %s\n' "$*" >&2; }
info() { printf 'mcp-firewall: %s\n' "$*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# MCP server ports (must match scripts/setup-mcp.sh).
MCP_PORTS=(8180 8280)

has_cmd ufw || die "ufw is not installed"

# sudo is required to manage ufw unless already root.
SUDO=""
if [[ "$(id -u)" != "0" ]]; then
  has_cmd sudo || die "must run as root or have sudo available"
  SUDO="sudo"
fi

# Default docker bridge subnet (the "main" docker network).
SUBNET="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | head -n1 | tr -d '[:space:]')"
[[ -n "$SUBNET" ]] || die "could not determine the docker bridge subnet (is docker running?)"
info "docker bridge subnet: $SUBNET"

# Cache sudo credentials up front so we don't prompt once per rule.
if [[ -n "$SUDO" ]]; then
  info "managing ufw needs sudo (you may be prompted for your password)"
  $SUDO -v || die "sudo authentication failed"
fi

if ! $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
  warn "ufw is not active; rules will be stored but not enforced until you run 'ufw enable'"
fi

ufw_status="$($SUDO ufw status 2>/dev/null)"

for port in "${MCP_PORTS[@]}"; do
  if printf '%s\n' "$ufw_status" | grep -F "${port}/tcp" | grep -qF "$SUBNET"; then
    info "already allowed: ${port}/tcp from ${SUBNET}"
  elif $SUDO ufw allow proto tcp from "$SUBNET" to any port "$port"; then
    info "allowed ${port}/tcp from ${SUBNET}"
  else
    warn "failed to allow ${port}/tcp"
  fi
done
