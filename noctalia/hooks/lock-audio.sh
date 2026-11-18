#!/bin/bash
set -euo pipefail

state_file="${XDG_RUNTIME_DIR:-$HOME/.cache}/noctalia-lock-audio-state"

case "${1:-}" in
    lock)
        if [[ ! -r "$state_file" ]]; then
            volume_state=$(wpctl get-volume @DEFAULT_AUDIO_SINK@) || exit 0
            umask 077
            if [[ "$volume_state" == *"[MUTED]"* ]]; then
                printf 'muted\n' > "$state_file"
            else
                printf 'unmuted\n' > "$state_file"
            fi
        fi
        wpctl set-mute @DEFAULT_AUDIO_SINK@ 1
        ;;
    unlock)
        if [[ -r "$state_file" ]]; then
            read -r previous_state < "$state_file"
            if [[ "$previous_state" == "unmuted" ]]; then
                wpctl set-mute @DEFAULT_AUDIO_SINK@ 0
            fi
            rm -f -- "$state_file"
        fi
        ;;
    *)
        printf 'Usage: %s {lock|unlock}\n' "$0" >&2
        exit 2
        ;;
esac
