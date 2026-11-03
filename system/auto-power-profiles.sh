#!/bin/bash
# ⚠️ Change this if your adapter name differs!
AC_PATH="/sys/class/power_supply/ACAD/online"

set_profile() {
    case "$1" in
        "1") # AC connected
            echo "  Setting power profile to performance." | systemd-cat -t power-profile-auto -p info
            powerprofilesctl set performance
            ;;
        "0") # AC disconnected
            echo "  Setting power profile to power saver." | systemd-cat -t power-profile-auto -p info
            powerprofilesctl set power-saver
            ;;
    esac
}

if [[ -f "$AC_PATH" ]]; then
    AC_STATE=$(cat "$AC_PATH")
    set_profile "$AC_STATE"
else
    echo "⚠️ Adapter path not found: $AC_PATH" | systemd-cat -t power-profile-auto -p warning
fi
