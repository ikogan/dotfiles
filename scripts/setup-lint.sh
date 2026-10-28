#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# setup-lint — build the dotfiles-lint image and link each linter into
# ~/.local/bin. Each link points at scripts/lint-container.sh, which starts the
# matching tool in a container. Requires a docker-compatible runtime (docker or
# podman); without one, a warning is printed and nothing is linked.
#
# Usage:
#   setup-lint

set -uo pipefail

warn() { printf 'setup-lint: warning: %s\n' "$*" >&2; }
info() { printf 'setup-lint: %s\n' "$*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Resolve the dotfiles repo root (parent of scripts/), following symlinks.
SELF="${BASH_SOURCE[0]}"
if has_cmd readlink; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LINT_SRC="$REPO_DIR/lint"
WRAPPER="$REPO_DIR/scripts/lint-container.sh"

IMAGE="dotfiles-lint:latest"
TOOLS=(shellcheck ruff luacheck hadolint)

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

main() {
  local runtime tool

  if ! runtime="$(detect_runtime)"; then
    warn "no docker-compatible container runtime (docker or podman) is working; linters were not set up"
    warn "  install and start one, then re-run: setup-lint"
    return 0
  fi

  info "building $IMAGE from $LINT_SRC with $runtime (cached layers are reused)..."
  if ! "$runtime" build -t "$IMAGE" "$LINT_SRC"; then
    warn "failed to build $IMAGE; linters were not set up"
    return 0
  fi

  mkdir -p "$HOME/.local/bin"
  for tool in "${TOOLS[@]}"; do
    ln -sfn "$WRAPPER" "$HOME/.local/bin/$tool"
    info "linked ~/.local/bin/$tool"
  done
}

main "$@"
