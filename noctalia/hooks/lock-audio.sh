#!/bin/bash
# Mute every hardware audio sink while the session is locked. On unlock,
# unmute only the sinks this script muted, so a sink the user muted before
# locking stays muted. Sinks are tracked by node.name because node IDs change
# when a device is unplugged and plugged back in.
set -uo pipefail

state_file="${XDG_RUNTIME_DIR:-$HOME/.cache}/noctalia-lock-audio-state"

log() {
    logger -t lock-audio -- "$*"
}

# Print "<id>\t<node.name>" for every sink backed by a device, which skips
# virtual sinks such as null sinks, filters, and loopbacks.
device_sinks() {
    pw-dump | jq -r '
        .[]
        | select(.type == "PipeWire:Interface:Node")
        | .info.props
        | select(."media.class" == "Audio/Sink" and ."device.id" != null)
        | "\(."object.id")\t\(."node.name")"'
}

is_muted() {
    local volume_state
    volume_state=$(wpctl get-volume "$1") || return 1
    [[ "$volume_state" == *"[MUTED]"* ]]
}

lock() {
    local sinks id name
    sinks=$(device_sinks) || { log "lock: failed to list sinks"; exit 1; }
    umask 077
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] || continue
        if is_muted "$id"; then
            continue
        fi
        if wpctl set-mute "$id" 1; then
            # Append, so a repeated lock event keeps sinks muted the first time.
            grep -qxF -- "$name" "$state_file" 2>/dev/null \
                || printf '%s\n' "$name" >> "$state_file"
            log "lock: muted $name"
        else
            log "lock: failed to mute $name"
        fi
    done <<< "$sinks"
}

unlock() {
    local sinks id name
    [[ -r "$state_file" ]] || return 0
    sinks=$(device_sinks) || { log "unlock: failed to list sinks"; exit 1; }
    declare -A ids=()
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] && ids["$name"]="$id"
    done <<< "$sinks"
    while read -r name; do
        [[ -n "$name" ]] || continue
        if [[ -z "${ids[$name]:-}" ]]; then
            log "unlock: $name is gone, can't unmute it"
        elif wpctl set-mute "${ids[$name]}" 0; then
            log "unlock: unmuted $name"
        else
            log "unlock: failed to unmute $name"
        fi
    done < "$state_file"
    rm -f -- "$state_file"
}

case "${1:-}" in
    lock) lock ;;
    unlock) unlock ;;
    *)
        printf 'Usage: %s {lock|unlock}\n' "$0" >&2
        exit 2
        ;;
esac
