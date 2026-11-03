#!/bin/bash
# Allow the MCP ports from every docker bridge subnet through ufw.
#
# Usage: ufw-mcp-rules [--check]
#   --check  exit 10 if rules are missing, 0 otherwise (no root needed)
#   default  add the missing rules (needs root)

UFW_RULES="/etc/ufw/user.rules"
NEEDS_INSTALL=10

# MCP server ports (must match scripts/setup-mcp.sh).
MCP_PORTS=(8180 8280 8380)

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Docker bridge subnets: the docker0 gateway subnet plus every docker bridge
# network subnet, since containers can use either.
ufw_subnets() {
    local net_id s
    local -a subnets=()

    s="$(ip -4 route show dev docker0 proto kernel scope link 2>/dev/null | awk '{print $1}' | head -n1)"
    [[ -n "${s}" ]] && subnets+=("${s}")

    if has_cmd docker; then
        while read -r net_id; do
            while read -r s; do
                [[ -n "${s}" ]] && subnets+=("${s}")
            done < <(docker network inspect "${net_id}" -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null)
        done < <(docker network ls -q --filter driver=bridge 2>/dev/null)
    fi

    printf '%s\n' "${subnets[@]}" | awk 'NF && !seen[$0]++'
}

# Prints "port subnet" for each missing rule.
ufw_missing_rules() {
    local subnet port
    while read -r subnet; do
        for port in "${MCP_PORTS[@]}"; do
            if ! grep -qF "### tuple ### allow tcp ${port} 0.0.0.0/0 any ${subnet} in" "${UFW_RULES}" 2>/dev/null; then
                printf '%s %s\n' "${port}" "${subnet}"
            fi
        done
    done < <(ufw_subnets)
}

has_cmd ufw || exit 0

if [[ "$(ufw_subnets)" = "" ]]; then
    echo "⚠️  Could not determine any docker bridge subnet. Skipping ufw rules for MCP ports." >&2
    exit 0
fi

if [[ "${1:-}" = "--check" ]]; then
    [[ -z "$(ufw_missing_rules)" ]] && exit 0
    exit "${NEEDS_INSTALL}"
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "ufw-mcp-rules: must run as root to add rules." >&2
    exit 1
fi

while read -r port subnet; do
    [[ -n "${port}" ]] || continue
    echo "Allowing ${port}/tcp from ${subnet}..."
    ufw allow proto tcp from "${subnet}" to any port "${port}" >/dev/null || echo "⚠️  Failed to allow ${port}/tcp from ${subnet}." >&2
done < <(ufw_missing_rules)

if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "⚠️  ufw is not active; rules are stored but not enforced until you run 'ufw enable'." >&2
fi
