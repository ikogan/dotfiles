#!/usr/bin/env bash
# gitea-mcp-run — start gitea-mcp with the Gitea access token read from the
# libsecret keyring (attributes service=gitea-mcp, url=<host>). The token is
# passed in the environment only and never written to disk.
#
# Store it with:
#   secret-tool store --label='gitea-mcp token' service gitea-mcp url https://git.gaea.mythicnet.org

set -uo pipefail

GITEA_HOST="${GITEA_HOST:-https://git.gaea.mythicnet.org}"

token="$(secret-tool lookup service gitea-mcp url "$GITEA_HOST")"
if [[ -z "$token" ]]; then
  echo "gitea-mcp-run: no token in the keyring for $GITEA_HOST (service=gitea-mcp)" >&2
  exit 1
fi

export GITEA_ACCESS_TOKEN="$token" GITEA_HOST
exec "$HOME/.local/bin/gitea-mcp" "$@"
