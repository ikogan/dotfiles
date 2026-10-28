#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# lint-container — run a linter from the dotfiles-lint image.
#
# Reached through symlinks named after the tool (created by setup-lint), e.g.
# ~/.local/bin/ruff -> scripts/lint-container.sh. The tool to run is taken from
# the name this script was invoked as. The current directory is mounted at the
# same path, so relative paths and project config work as they do on the host.

set -uo pipefail

IMAGE="dotfiles-lint:latest"
TOOLS="shellcheck ruff luacheck hadolint"

die() { printf '%s: error: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Print the name of a working docker-compatible runtime, if there is one.
detect_runtime() {
  if has_cmd docker && docker info >/dev/null 2>&1; then
    printf 'docker'
    return 0
  fi
  if has_cmd podman && podman info >/dev/null 2>&1; then
    printf 'podman'
    return 0
  fi
  return 1
}

TOOL="$(basename "$0")"
case " ${TOOLS} " in
  *" ${TOOL} "*) ;;
  *) die "unknown linter '${TOOL}' (expected one of: ${TOOLS})" ;;
esac

RUNTIME="$(detect_runtime)" || die "no docker-compatible container runtime (docker or podman) is working"
"$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1 || die "image ${IMAGE} is not built; run setup-lint"

exec "$RUNTIME" run --rm -i \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e RUFF_CACHE_DIR=/tmp/ruff-cache \
  --tmpfs /tmp \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  "$IMAGE" "$TOOL" "$@"
