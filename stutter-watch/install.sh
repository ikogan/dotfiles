#!/bin/bash
#
# Install stutter-watch: the recorder script, its user service, docs, the
# MangoHud profile, and the GeForce NOW wiring when that Flatpak is present.
# The main dotfiles install.sh doesn't run this.
#
# Usage:
#   ./install.sh            user-level install
#   ./install.sh --system   also install the /usr/local/bin/game-performance
#                           wrapper with sudo (game detection and MangoHud)

set -euo pipefail

SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/stutter-watch"
GFN_APP="com.nvidia.geforcenow"
GFN_DESKTOP="${HOME}/.local/share/applications/${GFN_APP}.desktop"
MANGOHUD_CONF="${HOME}/.config/MangoHud/stutter-watch.conf"
# Beside hyprland.lua, not in config/, which the dotfiles link to the repo.
HYPR_MAIN="${HOME}/.config/hypr/hyprland.lua"
HYPR_BINDS="${HOME}/.config/hypr/stutter_watch.lua"
HYPR_REQUIRE='require("stutter_watch")'

has_cmd() { command -v "$1" >/dev/null 2>&1; }
info() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m%s\033[0m\n' "$*" >&2; }

SYSTEM=0
case "${1:-}" in
    "") ;;
    --system) SYSTEM=1 ;;
    -h|--help) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) warn "Unknown option: $1"; exit 1 ;;
esac

has_cmd python3 || { warn "⚠️  python3 not found; stutter-watch needs it."; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 \
    || { warn "⚠️  systemd user session unavailable."; exit 1; }
for EACH in hyprctl notify-send gputop mangohud flock; do
    has_cmd "${EACH}" || warn "⚠️  ${EACH} not found; some stutter-watch data won't be recorded."
done

info "Linking stutter-watch..."
mkdir -p "${HOME}/.local/bin" "${HOME}/.local/share/doc/stutter-watch" \
    "${HOME}/.config/systemd/user" "${STATE_DIR}/frametimes"
ln -sf "${SCRIPTPATH}/stutter-watch" "${HOME}/.local/bin/stutter-watch"
ln -sf "${SCRIPTPATH}/README.md" "${HOME}/.local/share/doc/stutter-watch/README.md"
ln -sf "${SCRIPTPATH}/stutter-watch.service" "${HOME}/.config/systemd/user/stutter-watch.service"

info "Writing the MangoHud profile..."
mkdir -p "$(dirname "${MANGOHUD_CONF}")"
sed "s|@FRAMETIMES@|${STATE_DIR}/frametimes|" "${SCRIPTPATH}/mangohud.conf" > "${MANGOHUD_CONF}"

info "Starting the stutter-watch service..."
systemctl --user daemon-reload
systemctl --user enable stutter-watch.service
systemctl --user restart stutter-watch.service

if has_cmd flatpak && flatpak info --user "${GFN_APP}" >/dev/null 2>&1; then
    info "Wiring up GeForce NOW..."
    flatpak override --user "${GFN_APP}" --env=MANGOHUD=1 --env=MANGOHUD_CONFIGFILE="${MANGOHUD_CONF}"
    flatpak list --user --columns=application | grep -qx org.freedesktop.Platform.VulkanLayer.MangoHud \
        || warn "⚠️  MangoHud Flatpak layer not installed; GeForce NOW frame times won't be logged. Install the branch matching its runtime (flatpak info ${GFN_APP})."
    if [[ -f "${GFN_DESKTOP}" ]] && ! grep -q '^Exec=.*game-performance' "${GFN_DESKTOP}"; then
        cp "${GFN_DESKTOP}" "${STATE_DIR}/${GFN_APP}.desktop.orig"
        sed -i 's|^Exec=|Exec=env STUTTER_WATCH_MANGOHUD=0 game-performance |' "${GFN_DESKTOP}"
    fi
fi

if [[ "${SYSTEM}" == 1 ]]; then
    info "Installing the game-performance wrapper (sudo)..."
    sudo install -Dm755 "${SCRIPTPATH}/game-performance" /usr/local/bin/game-performance
elif [[ ! -x /usr/local/bin/game-performance ]]; then
    warn "⚠️  game-performance wrapper not installed; games won't be detected. Rerun with --system to add it."
fi

if [[ -f "${HYPR_MAIN}" ]]; then
    info "Adding the stutter-watch Hyprland binds..."
    cat > "${HYPR_BINDS}" <<EOF
-- Written by stutter-watch/install.sh; removed by uninstall.sh.
-- Super+Shift+M marks a stutter; Super+Shift+B turns blur off for 2 minutes.
hl.bind("SUPER + SHIFT + M", hl.dsp.exec_cmd("${HOME}/.local/bin/stutter-watch mark"))
hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("${HOME}/.local/bin/stutter-watch probe"))
EOF
    grep -qxF "${HYPR_REQUIRE}" "${HYPR_MAIN}" || printf '\n%s\n' "${HYPR_REQUIRE}" >> "${HYPR_MAIN}"
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && has_cmd hyprctl; then
        hyprctl reload >/dev/null || warn "⚠️  Hyprland config reload failed; the stutter-watch binds need it."
    fi
else
    warn "⚠️  ${HYPR_MAIN} not found; skipping the stutter-watch Hyprland binds."
fi

info "🎉 stutter-watch installed. Check it with: stutter-watch status"
