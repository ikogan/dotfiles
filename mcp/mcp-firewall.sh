#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# mcp-firewall — open the MCP server ports to the docker bridge network only.
#
# Uses ufw (when present) to allow inbound TCP to the MCP servers
# (kubernetes-mcp-server on 8180, mcp-grafana on 8280) exclusively from the
# default docker bridge subnet (e.g. 172.18.0.0/16), so containers can reach the
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
MCP_PORTS=(8180 8280 8380)

has_cmd ufw || die "ufw is not installed"

# sudo is required to manage ufw unless already root.
SUDO=""
if [[ "$(id -u)" != "0" ]]; then
  has_cmd sudo || die "must run as root or have sudo available"
  SUDO="sudo"
fi

# Subnets to allow: the docker0 interface's subnet (the address containers use
# as their gateway to reach the host) plus the subnet of every docker bridge
# network. These can differ, and they can change, so collect all of them.
SUBNETS=()
add_subnet() {
  local s="$1" existing
  [[ -n "$s" ]] || return 0
  for existing in "${SUBNETS[@]}"; do
    [[ "$existing" == "$s" ]] && return 0
  done
  SUBNETS+=("$s")
}

add_subnet "$(ip -4 route show dev docker0 proto kernel scope link 2>/dev/null | awk '{print $1}' | head -n1)"
if has_cmd docker; then
  while read -r net_id; do
    docker network inspect "$net_id" -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
      | while read -r s; do add_subnet "$s"; done
  done < <(docker network ls -q --filter driver=bridge 2>/dev/null)
fi

[[ ${#SUBNETS[@]} -gt 0 ]] || die "could not determine any docker bridge subnet (is docker running?)"
info "docker bridge subnets: ${SUBNETS[*]}"

# Cache sudo credentials up front so we don't prompt once per rule.
if [[ -n "$SUDO" ]]; then
  info "managing ufw needs sudo (you may be prompted for your password)"
  $SUDO -v || die "sudo authentication failed"
fi

if ! $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
  warn "ufw is not active; rules will be stored but not enforced until you run 'ufw enable'"
fi

ufw_status="$($SUDO ufw status 2>/dev/null)"

for subnet in "${SUBNETS[@]}"; do
  for port in "${MCP_PORTS[@]}"; do
    if printf '%s\n' "$ufw_status" | grep -F "${port}/tcp" | grep -qF "$subnet"; then
      info "already allowed: ${port}/tcp from ${subnet}"
    elif $SUDO ufw allow proto tcp from "$subnet" to any port "$port"; then
      info "allowed ${port}/tcp from ${subnet}"
    else
      warn "failed to allow ${port}/tcp from ${subnet}"
    fi
  done
done
