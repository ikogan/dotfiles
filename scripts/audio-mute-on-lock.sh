#!/bin/bash
# Mute the default audio sink while the session is locked. On unlock, unmute
# only if this script was the one that muted it, so a sink the user muted
# before locking stays muted.

SINK="@DEFAULT_AUDIO_SINK@"
MARKER="${XDG_RUNTIME_DIR:-/tmp}/audio-mute-on-lock.muted"

SESSION_PATH="$(busctl --system call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager GetSession s "${XDG_SESSION_ID}" | awk '{print $2}' | tr -d '"')"

is_muted() {
    wpctl get-volume "${SINK}" | grep -q "\[MUTED\]"
}

on_lock() {
    [[ -e "${MARKER}" ]] && return
    if ! is_muted; then
        touch "${MARKER}"
        wpctl set-mute "${SINK}" 1
    fi
}

on_unlock() {
    [[ -e "${MARKER}" ]] || return
    rm -f "${MARKER}"
    wpctl set-mute "${SINK}" 0
}

dbus-monitor --system \
    "type='signal',interface='org.freedesktop.login1.Session',path='${SESSION_PATH}',member='Lock'" \
    "type='signal',interface='org.freedesktop.login1.Session',path='${SESSION_PATH}',member='Unlock'" |
while read -r line; do
    case "${line}" in
        *"member=Lock"*) on_lock ;;
        *"member=Unlock"*) on_unlock ;;
    esac
done
