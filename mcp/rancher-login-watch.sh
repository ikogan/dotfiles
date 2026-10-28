#!/usr/bin/env bash
# rancher-login-watch — notify when kubernetes-mcp-server reports that its
# Rancher credentials were rejected, so `rancher login` can be run.
#
# Follows the kubernetes-mcp-server journal and sends a desktop notification
# when it logs a 401 for the exec credential. The server retries discovery
# about every 30 seconds, so a notification is sent at the start of each
# failure episode and re-armed after a gap longer than REARM_SECONDS.

set -uo pipefail

UNIT="kubernetes-mcp-server"
PATTERN="the server has asked for the client to provide credentials"
LOGIN_CMD="${RANCHER_LOGIN_CMD:-rancher login https://rancher.gaea.mythicnet.org}"
REARM_SECONDS=120

last_seen=0

notify() {
  logger -t rancher-login-watch "Rancher credentials rejected by $UNIT"
  notify-send --urgency=critical --app-name=rancher-login-watch \
    "Rancher login required" \
    "$UNIT lost its Rancher credentials. Run: $LOGIN_CMD"
}

journalctl --user -u "$UNIT" -f -n 0 -o cat | while IFS= read -r line; do
  [[ "$line" == *"$PATTERN"* ]] || continue
  now=$(date +%s)
  if (( now - last_seen > REARM_SECONDS )); then
    notify
  fi
  last_seen=$now
done
