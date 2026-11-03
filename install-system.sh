#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"
SYSTEM_DIR="${SCRIPTPATH}/system"
NEEDS_INSTALL=10

# The desktop user who owns the MCP servers and the repo checkout.
OWNER="${SUDO_USER:-$(id -un)}"

DO_POWER=""
DO_UFW=""
DO_DOCKER=""

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

info() {
    echo -e "\e[36m$1\e[0m"
}

warn() {
    echo -e "\e[33m$1\e[0m"
}

# Source file, destination path, and mode for each installed file.
# Source files may contain @USER@ and @REPO@ placeholders.
# shellcheck disable=SC2034 # read through a nameref in targets_*
POWER_TARGETS=(
    "auto-power-profiles.sh:/usr/local/libexec/auto-power-profiles.sh:0755"
    "99-power-profile.rules:/etc/udev/rules.d/99-power-profile.rules:0644"
    "auto-power-profiles.service:/etc/systemd/system/auto-power-profiles.service:0644"
)

# shellcheck disable=SC2034 # read through a nameref in targets_*
UFW_TARGETS=(
    "ufw-mcp-rules.sh:/usr/local/libexec/ufw-mcp-rules:0755"
)

# shellcheck disable=SC2034 # read through a nameref in targets_*
DOCKER_TARGETS=(
    "docker-network-refresh.sh:/usr/local/libexec/docker-network-refresh:0755"
    "docker-network-refresh.service:/etc/systemd/system/docker-network-refresh.service:0644"
)

render() {
    sed -e "s|@USER@|${OWNER}|g" -e "s|@REPO@|${SCRIPTPATH}|g" "$1"
}

# Succeeds if any target is missing or differs from its rendered source.
targets_need_install() {
    local -n targets="$1"
    local entry src dest
    for entry in "${targets[@]}"; do
        IFS=: read -r src dest _ <<< "${entry}"
        if ! render "${SYSTEM_DIR}/${src}" | cmp -s - "${dest}"; then
            return 0
        fi
    done
    return 1
}

targets_install() {
    local -n targets="$1"
    local entry src dest mode tmp
    for entry in "${targets[@]}"; do
        IFS=: read -r src dest mode <<< "${entry}"
        if render "${SYSTEM_DIR}/${src}" | cmp -s - "${dest}"; then
            continue
        fi
        info "Installing ${dest}..."
        tmp="$(mktemp)" || return 1
        render "${SYSTEM_DIR}/${src}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
        install -D --mode="${mode}" "${tmp}" "${dest}" || { rm -f "${tmp}"; return 1; }
        rm -f "${tmp}"
    done
}

power_needs_install() {
    targets_need_install POWER_TARGETS
}

power_install() {
    targets_install POWER_TARGETS || return 1
    systemctl daemon-reload || return 1
    udevadm control --reload || return 1
}

ufw_needs_install() {
    has_cmd ufw || return 1
    targets_need_install UFW_TARGETS && return 0
    "${SYSTEM_DIR}/ufw-mcp-rules.sh" --check
    [[ $? -eq ${NEEDS_INSTALL} ]]
}

ufw_install() {
    targets_install UFW_TARGETS || return 1
    /usr/local/libexec/ufw-mcp-rules
}

docker_needs_install() {
    targets_need_install DOCKER_TARGETS && return 0
    ! systemctl is-enabled --quiet docker-network-refresh.service 2>/dev/null
}

docker_install() {
    targets_install DOCKER_TARGETS || return 1
    systemctl daemon-reload || return 1
    systemctl enable docker-network-refresh.service || return 1
}

usage() {
    echo "Usage: $0 [--power] [--ufw] [--docker]" >&2
    exit 2
}

for arg in "$@"; do
    case "${arg}" in
        --power) DO_POWER="true" ;;
        --ufw) DO_UFW="true" ;;
        --docker) DO_DOCKER="true" ;;
        *) usage ;;
    esac
done

if [[ -z "${DO_POWER}" ]] && [[ -z "${DO_UFW}" ]] && [[ -z "${DO_DOCKER}" ]]; then
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    needs=""
    if [[ -n "${DO_POWER}" ]] && power_needs_install; then
        echo "Power profile system files need to be installed."
        needs="true"
    fi
    if [[ -n "${DO_UFW}" ]] && ufw_needs_install; then
        echo "ufw rules for MCP ports need to be installed."
        needs="true"
    fi
    if [[ -n "${DO_DOCKER}" ]] && docker_needs_install; then
        echo "Docker refresh unit needs to be installed."
        needs="true"
    fi
    if [[ -n "${needs}" ]]; then
        exit "${NEEDS_INSTALL}"
    fi
    info "System files are up to date."
    exit 0
fi

if [[ -n "${DO_POWER}" ]]; then
    for cmd in systemctl udevadm powerprofilesctl; do
        has_cmd "${cmd}" || warn "⚠️  ${cmd} is not installed. Power profile automation will not work until it is."
    done
    if power_needs_install; then
        power_install || warn "⚠️  Failed to install power profile files."
        info "🎉 Power profile system files installed."
    fi
fi

if [[ -n "${DO_UFW}" ]] && ufw_needs_install; then
    ufw_install
    info "🎉 ufw rules for MCP ports installed."
fi

if [[ -n "${DO_DOCKER}" ]] && docker_needs_install; then
    docker_install || warn "⚠️  Failed to install docker refresh unit."
    info "🎉 Docker refresh unit installed."
fi
