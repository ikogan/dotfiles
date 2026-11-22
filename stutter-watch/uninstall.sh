#!/bin/bash
#
# Undo install.sh, including the /usr/local/bin/game-performance wrapper if
# present (uses sudo). Recorded data under ~/.local/state/stutter-watch is kept.

set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/stutter-watch"
GFN_APP="com.nvidia.geforcenow"
GFN_DESKTOP="${HOME}/.local/share/applications/${GFN_APP}.desktop"
UNIT="${HOME}/.config/systemd/user/stutter-watch.service"
HYPR_MAIN="${HOME}/.config/hypr/hyprland.lua"
HYPR_BINDS="${HOME}/.config/hypr/stutter_watch.lua"

has_cmd() { command -v "$1" >/dev/null 2>&1; }
info() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m%s\033[0m\n' "$*" >&2; }

if systemctl --user show-environment >/dev/null 2>&1; then
    info "Stopping the stutter-watch service..."
    systemctl --user disable --now stutter-watch.service 2>/dev/null || true
    rm -f "${UNIT}"
    systemctl --user daemon-reload
else
    warn "⚠️  systemd user session unavailable; remove ${UNIT} by hand."
fi

info "Removing stutter-watch files..."
rm -f "${HOME}/.local/bin/stutter-watch" \
    "${HOME}/.local/share/doc/stutter-watch/README.md" \
    "${HOME}/.config/MangoHud/stutter-watch.conf"
rmdir "${HOME}/.local/share/doc/stutter-watch" 2>/dev/null || true

if has_cmd flatpak && flatpak info --user "${GFN_APP}" >/dev/null 2>&1; then
    info "Unwiring GeForce NOW..."
    flatpak override --user "${GFN_APP}" --unset-env=MANGOHUD --unset-env=MANGOHUD_CONFIGFILE
fi
if [[ -f "${GFN_DESKTOP}" ]] && grep -q '^Exec=env STUTTER_WATCH_MANGOHUD=0 game-performance ' "${GFN_DESKTOP}"; then
    if [[ -f "${STATE_DIR}/${GFN_APP}.desktop.orig" ]]; then
        mv "${STATE_DIR}/${GFN_APP}.desktop.orig" "${GFN_DESKTOP}"
    else
        sed -i 's|^Exec=env STUTTER_WATCH_MANGOHUD=0 game-performance |Exec=|' "${GFN_DESKTOP}"
    fi
fi

if [[ -e /usr/local/bin/game-performance ]]; then
    info "Removing the game-performance wrapper (sudo)..."
    sudo rm -f /usr/local/bin/game-performance
fi

info "Removing the stutter-watch Hyprland binds..."
if [[ -f "${HYPR_MAIN}" ]]; then
    sed -i '/^require("stutter_watch")$/d' "${HYPR_MAIN}"
fi
rm -f "${HYPR_BINDS}"

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && has_cmd hyprctl; then
    hyprctl reload >/dev/null || warn "⚠️  Hyprland config reload failed; the stutter-watch binds stay until it reloads."
fi

info "stutter-watch removed. Recorded data is still in ${STATE_DIR}."
