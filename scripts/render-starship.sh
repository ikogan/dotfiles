#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# render-starship — generate the live Starship config (~/.config/starship.toml)
# from the base config in this repo plus the palette Noctalia renders into its
# cache.
#
# The live file is a regular file outside the repo. Noctalia updates its
# palette block in place on wallpaper changes, which only touches the live
# file, so the repo stays clean. Re-run this after editing starship.toml in
# the repo, since the live file is a copy rather than a link.
#
# Usage:
#   render-starship

set -uo pipefail

info() { printf 'render-starship: %s\n' "$*"; }
warn() { printf 'render-starship: warning: %s\n' "$*" >&2; }

# Resolve the dotfiles repo root (parent of scripts/), following symlinks.
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

BASE="$REPO_DIR/starship.toml"
TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"
PALETTE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia/starship-palette.toml"
marker_begin="# >>> NOCTALIA STARSHIP PALETTE >>>"
marker_end="# <<< NOCTALIA STARSHIP PALETTE <<<"

[[ -f "$BASE" ]] || { warn "missing $BASE"; exit 1; }
mkdir -p "$(dirname "$TARGET")"

# A previous install linked the live path into the repo. Replace the link so
# Noctalia and this script write to a regular file instead.
if [[ -L "$TARGET" ]]; then
  rm -f "$TARGET"
  info "replaced symlink $TARGET"
fi

tmp="$(mktemp "${TARGET}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

has_palette=0
[[ -s "$PALETTE" ]] && has_palette=1

# Copy the base config, dropping any palette reference, and add one after the
# schema line when there is a palette to reference.
awk -v palette="$has_palette" '
  /^palette[[:space:]]*=/ { next }
  { print }
  /^"\$schema"/ && palette == "1" { print "palette = \"noctalia\"" }
' "$BASE" >"$tmp"

if [[ "$has_palette" == "1" ]]; then
  {
    echo ""
    echo "$marker_begin"
    cat "$PALETTE"
    echo "$marker_end"
  } >>"$tmp"
else
  warn "no palette at $PALETTE; rendering without it"
fi

chmod 0644 "$tmp"
if [[ -f "$TARGET" ]] && cmp -s "$TARGET" "$tmp"; then
  info "$TARGET is up to date"
else
  mv "$tmp" "$TARGET"
  trap - EXIT
  info "wrote $TARGET"
fi
