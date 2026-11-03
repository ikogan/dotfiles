#!/bin/bash
# Runs after docker starts or restarts: refresh the ufw rules for the current
# docker bridge subnets, then re-run setup-mcp as the desktop user so the MCP
# servers rebind to the current docker gateway.
#
# @USER@ and @REPO@ are filled in by install-system.sh.

OWNER="@USER@"
REPO="@REPO@"

if [[ -x /usr/local/libexec/ufw-mcp-rules ]]; then
    /usr/local/libexec/ufw-mcp-rules || echo "ufw rule refresh failed." >&2
fi

uid="$(id -u "${OWNER}")" || exit 1
if [[ ! -S "/run/user/${uid}/bus" ]]; then
    echo "No user session for ${OWNER}; run setup-mcp after logging in to rebind the MCP servers." >&2
    exit 0
fi

home="$(getent passwd "${OWNER}" | cut -d: -f6)"
runuser -u "${OWNER}" -- env HOME="${home}" XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    "${REPO}/scripts/setup-mcp.sh" --rebind --force
