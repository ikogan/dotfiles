#!/usr/bin/env bash
# gitea-mcp-run — start gitea-mcp with the Gitea access token read from the
# libsecret keyring (attributes service=gitea-mcp, url=<host>). The token is
# passed in the environment only and never written to disk.
#
# The host comes from GITEA_HOST, set in the environment or in ~/.dotfilesrc
# (systemd doesn't load the shell config, so this script reads it).
#
# Store the token with:
#   secret-tool store --label='gitea-mcp token' service gitea-mcp url "$GITEA_HOST"

set -uo pipefail

if [[ -z "${GITEA_HOST:-}" && -f "$HOME/.dotfilesrc" ]]; then
  . "$HOME/.dotfilesrc"
fi
if [[ -z "${GITEA_HOST:-}" ]]; then
  echo "gitea-mcp-run: GITEA_HOST is not set; add it to ~/.dotfilesrc" >&2
  exit 1
fi

token="$(secret-tool lookup service gitea-mcp url "$GITEA_HOST")"
if [[ -z "$token" ]]; then
  echo "gitea-mcp-run: no token in the keyring for $GITEA_HOST (service=gitea-mcp)" >&2
  exit 1
fi

export GITEA_ACCESS_TOKEN="$token" GITEA_HOST
exec "$HOME/.local/bin/gitea-mcp" "$@"
