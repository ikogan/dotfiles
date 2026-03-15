#!/bin/bash
ARGUMENTS=$(getopt -o s:dc --long server:,disconnect,connect -n 'vpn-script' -- "$@")
# shellcheck disable=SC2181
if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

eval set -- "$ARGUMENTS"

VPN_SERVER=""
ACTION="connect"  # default action

while true ; do
    case "$1" in
        -s|--server)
            VPN_SERVER="$2"
            shift 2
            ;;
        -d|--disconnect)
            ACTION="disconnect"
            shift
            ;;
        -c|--connect)
            ACTION="connect"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Unsupported argument '$1'" >&2
            exit 1
            ;;
    esac
done

# Handle disconnect action
if [ "$ACTION" = "disconnect" ]; then
    echo "Disconnecting VPN..."
    pkexec killall openconnect
    exit 0
fi

# Check if required server argument is provided for connect
if [ -z "$VPN_SERVER" ]; then
    echo "Error: --server argument is required for connection" >&2
    exit 1
fi

echo "Switching to Python 3.12..."
pyenv shell 3.12

echo "Activating OpenConnect Virtual Environment..."
source "${HOME}/.local/share/openconnect/venv/bin/activate"

openconnect-sso --server="$VPN_SERVER"
