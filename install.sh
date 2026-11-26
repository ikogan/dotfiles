#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"
HAVE_GUM=""
TEMP_DIR=""
PATH="${HOME}"/.local/bin:"${PATH}"
# Krew installs kubectl-krew here; kubectl only finds it on PATH.
PATH="${KREW_ROOT:-${HOME}/.krew}/bin:${PATH}"

if [[ "${SHELL}" = "/bin/fish" ]] || [[ "${SHELL}" = "/usr/bin/fish" ]]; then
    echo "The fish shell is not supported, change your shell to zsh." 1>&2
    exit 1
fi

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_devcontainer() {
    [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${DEVCONTAINER:-}" ]] || [[ -n "${CODESPACES:-}" ]] || [[ -f "/.dockerenv" && -d "/workspaces" ]]
}

has_battery() {
    local supply
    for supply in /sys/class/power_supply/*; do
        if [[ -f "${supply}/type" ]] && [[ "$(cat "${supply}/type")" = "Battery" ]]; then
            return 0
        fi
    done
    return 1
}

is_physical_device() {
    has_cmd systemd-detect-virt && ! systemd-detect-virt --quiet
}

pushd "${SCRIPTPATH}" &>/dev/null || exit

if ! has_cmd curl; then
    echo "❌ curl is required but not installed. Aborting." >&2
    exit 1
fi

if has_cmd git; then
    git submodule update --recursive --remote --init || \
        echo "⚠️  git is available, but submodule update failed. Submodule-dependent setup may be skipped."
else
    echo "⚠️  git is not installed. Skipping submodule update and submodule-dependent setup unless files already exist."
fi

if has_cmd gum; then
    HAVE_GUM="true"
fi

# Determine the operating system and architecture
LOCAL_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
LOCAL_ARCH=$(uname -m)
case "$LOCAL_ARCH" in
    x86_64)
        LOCAL_ARCH=("amd64" "x86_64")
        ;;
    *)
        # shellcheck disable=SC2128
        LOCAL_ARCH=("${LOCAL_ARCH}")
        ;;
esac

log() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log "$1"
    else
        echo -e "$1"
    fi
}

debug() {
    if [[ "${ENABLE_DEBUG}" ]]; then
        if [[ "${HAVE_GUM}" ]]; then
            gum log -l debug "$1"
        else
            echo -e "\e[34m$1\e[0m"
        fi
    fi
}

info() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log -l info "$1"
    else
        echo -e "\e[36m$1\e[0m"
    fi
}

warn() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log -l warn "$1"
    else
        echo -e "\e[33m$1\e[0m"
    fi
}

error() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log -l error "$1"
    else
        echo -e "\e[31m$1\e[0m"
    fi
}

download_latest_release() {
    local repo="$1"
    local binary_name="$2"
    local format="$3"

    local arch
    local latest_release_json
    local checksum_files=("checksums" "checksums.txt" "sha256sum" "sha256sum.txt")
    local checksum_url
    local binary_url

    if [[ -n "${format}" ]]; then
        format=".$format"
    fi

    info "🔍 Searching for the latest release of $binary_name from $repo..."

    latest_release_json=$(curl -s "https://api.github.com/repos/$repo/releases/latest")
    latest_release=$(echo "${latest_release_json}" | grep -e '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

    info "📦 Latest release found: $latest_release."

    for arch in "${LOCAL_ARCH[@]}"; do
        # https://github.com/cantino/mcfly/releases/download/v0.9.3/mcfly-v0.9.3-x86_64-unknown-linux-musl.tar.gz
        binary_url=$(echo "$latest_release_json" | grep -Ei "browser_download_url.*$binary_name.*$LOCAL_OS.*$arch(.*$latest_release)?(\.|$format)\"" | cut -d '"' -f 4)

        if [[ -n "$binary_url" ]]; then
            break
        fi

        binary_url=$(echo "$latest_release_json" | grep -Ei "browser_download_url.*$binary_name.*(.*$latest_release)?.*$arch.*$LOCAL_OS.*(\.|$format)\"" | cut -d '"' -f 4)

        if [[ -n "$binary_url" ]]; then
            break
        fi
    done

    if [[ -z "$binary_url" ]]; then
        error "❌ Error: Could not find the binary $binary_name for $LOCAL_OS/${LOCAL_ARCH[*]} in the latest release."

        if [[ "${ENABLE_DEBUG}" = "true" ]]; then
            if has_cmd yq; then
                debug "JSON from GitHub:"
                yq -P -C -o json <<< "${latest_release_json}"
            else
                debug "JSON from GitHub:"
                echo "${latest_release_json}"
            fi
        fi

	    return 1
    fi

    binary_download_name="$(basename "${binary_url}")"

    if [[ -n "${HAVE_GUM}" ]]; then
        gum spin --show-error --show-output --title="Downloading $binary_name for $LOCAL_OS/$arch..." -- \
            curl -sL --show-error "$binary_url" -o "${TEMP_DIR}/${binary_download_name}"
    else
        info "🔗 Downloading $binary_name for $LOCAL_OS/$arch..."
        curl -L --show-error "$binary_url" -o "${TEMP_DIR}/${binary_download_name}"
    fi

    for checksum_file in "${checksum_files[@]}"; do
        checksum_url=$(echo "$latest_release_json" | grep -E "browser_download_url.*$checksum_file\"" | cut -d '"' -f 4)

        if [[ -n "$checksum_url" ]]; then
            break
        fi
    done

    if [[ -n "$checksum_url" ]] && ! [[ "${INSANE_CHECKSUMS}" = "true" ]]; then
        if [[ -n "${HAVE_GUM}" ]]; then
            gum spin --show-error --show-output --title="Downloading checksums..." -- \
                curl -sL --show-error "$checksum_url" -o "${TEMP_DIR}/${binary_name}_checksums"
        else
            info "🔗 Downloading checksums..."
            curl -L --show-error "$checksum_url" -o "${TEMP_DIR}/${binary_name}_checksums"
        fi

        if ! [[ -f "${TEMP_DIR}/${binary_name}_checksums" ]]; then
            error "❌  Error: Failed to download checksums."
            return 1
        fi

        pushd "${TEMP_DIR}" 1>/dev/null || return 1
        checksum_output=$(sha256sum --ignore-missing -c "${TEMP_DIR}/${binary_name}_checksums" 2>&1)
        popd 1>/dev/null || return 1
        grep -q "OK" <<< "$checksum_output"
        check_result=$?
        rm "${TEMP_DIR}/${binary_name}_checksums"

        if ! [[ ${check_result} -eq 0 ]]; then
            error "❌ Checksum of ${binary_name} verification failed: ${checksum_output}"
            return 1
        fi

    else
        warn "⚠️  Warning: No checksums available for verification."
    fi

    mv "${TEMP_DIR}/${binary_download_name}" "${TEMP_DIR}/${binary_name}$format"
}

extract_download() {
    local binary_name="$1"
    local format="$2"

    info "📦 Extracting $binary_name..."
    case "$format" in
        tar.gz)
            tar -C "$TEMP_DIR" -xzf "${TEMP_DIR}/${binary_name}.$format"
            rm "${TEMP_DIR}/${binary_name}.$format"
            ;;
        tar.xz)
            tar -C "$TEMP_DIR" -xf "${TEMP_DIR}/${binary_name}.$format"
            rm "${TEMP_DIR}/${binary_name}.$format"
            ;;
        *)
            error "❌ Error: Unsupported format $format."
            return 1
            ;;
    esac
}

setup_temp_dir() {
    local candidate=""

    if ! has_cmd mktemp; then
        warn "⚠️  mktemp is unavailable. Skipping temp-directory based install steps."
        TEMP_DIR=""
        return 1
    fi

    test -d "${HOME}/.tmp" || mkdir -p "${HOME}/.tmp"
    candidate=$(mktemp -d "${HOME}/.tmp/dotfiles.XXXXX" 2>/dev/null)

    if [[ -z "${candidate}" ]] || [[ ! -d "${candidate}" ]]; then
        warn "⚠️  Could not create preferred temporary directory. Trying fallback in HOME."
        test -d "${HOME}/.tmp" || mkdir -p "${HOME}/.tmp"
        candidate=$(mktemp -d "${HOME}/.tmp/dotfiles-fallback.XXXXX" 2>/dev/null)
    fi

    if [[ -z "${candidate}" ]] || [[ ! -d "${candidate}" ]]; then
        warn "⚠️  Could not create any temporary directory. Skipping temp-directory based install steps."
        TEMP_DIR=""
        return 1
    fi

    TEMP_DIR="${candidate}"
    return 0
}

if ! has_cmd tmux; then
    warn "⚠️  tmux is not installed. Skipping tmux-specific setup."
fi

HAVE_ZSH=""
if has_cmd zsh; then
    HAVE_ZSH="true"
else
    warn "⚠️  zsh is not installed. Skipping zsh setup."
fi

HAVE_PYTHON_VENV=""
if has_cmd python3 && python3 -c 'import ensurepip' &>/dev/null; then
    HAVE_PYTHON_VENV="true"
else
    warn "⚠️  python3 with ensurepip is unavailable. Skipping Python virtualenv setup."
fi

IN_DEVCONTAINER=""
if is_devcontainer; then
    IN_DEVCONTAINER="true"
    info "Detected devcontainer environment. Skipping vim and plugin installation/setup."
fi

if setup_temp_dir; then
        trap '[[ -n "${TEMP_DIR}" ]] && rm -Rf "${TEMP_DIR:?}"' EXIT
else
        warn "⚠️  Continuing without temporary directory. Download/extract-based installs will be skipped."
fi

info "Installing for ${LOCAL_OS} on ${LOCAL_ARCH[*]}..."

info "Installing custom binaries..."
if [[ ! -d "${HOME}/.local/bin" ]]; then
    mkdir -p "${HOME}/.local/bin"
fi

if [[ -n "${TEMP_DIR}" ]]; then
    if download_latest_release "charmbracelet/gum" "gum" "tar.gz" \
        && extract_download "gum" "tar.gz" \
        && install --mode=0755 "${TEMP_DIR}/gum"*/"gum" "$HOME/.local/bin/gum"; then
        info "🎉 Successfully installed gum!"
    else
        warn "⚠️  Failed to install gum. Continuing without it."
    fi
else
    warn "⚠️  Skipping gum installation because temporary directory is unavailable."
fi

if has_cmd gum; then
    HAVE_GUM="true"
fi

if [[ -n "${TEMP_DIR}" ]]; then
    if download_latest_release "cantino/mcfly" "mcfly" "tar.gz" \
        && extract_download "mcfly" "tar.gz" \
        && install --mode=0755 "${TEMP_DIR}"/mcfly "${HOME}/.local/bin"; then
        info "🎉 Successfully installed McFly!"
    else
        warn "⚠️  Failed to install McFly."
    fi
else
    warn "⚠️  Skipping McFly installation because temporary directory is unavailable."
fi

TREE_SITTER_VERSION="v0.27.1"
info "Installing tree-sitter ${TREE_SITTER_VERSION}..."
case "$(uname -m)" in
    x86_64) TREE_SITTER_ARCH="x64" ;;
    aarch64|arm64) TREE_SITTER_ARCH="arm64" ;;
    *) TREE_SITTER_ARCH="" ;;
esac
if [[ -n "${TREE_SITTER_ARCH}" ]] \
    && curl -fsSL -o "${TEMP_DIR:-/tmp}/tree-sitter.gz" \
        "https://github.com/tree-sitter/tree-sitter/releases/download/${TREE_SITTER_VERSION}/tree-sitter-linux-${TREE_SITTER_ARCH}.gz" \
    && gunzip -f "${TEMP_DIR:-/tmp}/tree-sitter.gz" \
    && install --mode=0755 "${TEMP_DIR:-/tmp}/tree-sitter" "${HOME}/.local/bin/tree-sitter"; then
    info "🎉 Successfully installed tree-sitter!"
else
    warn "⚠️  Failed to install tree-sitter ${TREE_SITTER_VERSION}."
fi

if [[ -n "${TEMP_DIR}" ]]; then
    if download_latest_release "kubecolor/kubecolor" "kubecolor" "tar.gz" \
        && extract_download "kubecolor" "tar.gz" \
        && install --mode=0755 "${TEMP_DIR}/kubecolor" "$HOME/.local/bin/kubecolor"; then
        info "🎉 Successfully installed Kubecolor!"
    else
        warn "⚠️  Failed to install Kubecolor."
    fi
else
    warn "⚠️  Skipping Kubecolor installation because temporary directory is unavailable."
fi

if [[ -n "${TEMP_DIR}" ]]; then
    if download_latest_release "derailed/k9s" "k9s" "tar.gz" \
        && extract_download "k9s" "tar.gz" \
        && install --mode=0755 "${TEMP_DIR}/k9s" "$HOME/.local/bin/k9s"; then
        info "🎉 Successfully installed k9s!"
    else
        warn "⚠️  Failed to install k9s."
    fi
else
    warn "⚠️  Skipping k9s installation because temporary directory is unavailable."
fi

if [[ -n "${TEMP_DIR}" ]]; then
    if download_latest_release "cert-manager/cmctl" "cmctl" "tar.gz" \
        && extract_download "cmctl" "tar.gz" \
        && install --mode=0755 "${TEMP_DIR}/cmctl" "$HOME/.local/bin/cmctl"; then
        info "🎉 Successfully installed cert-manager CLI (cmctl)!"
    else
        warn "⚠️  Failed to install cert-manager CLI (cmctl)."
    fi
else
    warn "⚠️  Skipping cert-manager CLI (cmctl) installation because temporary directory is unavailable."
fi

if [[ -n "${TEMP_DIR}" ]]; then
    if download_latest_release "cli/cli" "gh" "tar.gz" \
        && extract_download "gh" "tar.gz" \
        && install --mode=0755 "${TEMP_DIR}"/gh_*/bin/gh "${HOME}/.local/bin/gh"; then
        info "🎉 Successfully installed GitHub CLI (gh)!"
    else
        warn "⚠️  Failed to install GitHub CLI (gh)."
    fi
else
    warn "⚠️  Skipping GitHub CLI (gh) installation because temporary directory is unavailable."
fi

download_latest_release "grafana/mcp-grafana" "mcp-grafana" "tar.gz" || exit 1
extract_download "mcp-grafana" "tar.gz" || exit 1
install --mode=0755 "${TEMP_DIR}/mcp-grafana" "$HOME/.local/bin/mcp-grafana" || exit 1
info "🎉 Successfully installed mcp-grafana!"

if [[ -n "${TEMP_DIR}" ]]; then
    if download_latest_release "containers/kubernetes-mcp-server" "kubernetes-mcp-server" "" \
        && install --mode=0755 "${TEMP_DIR}/kubernetes-mcp-server" "$HOME/.local/bin/kubernetes-mcp-server"; then
        info "🎉 Successfully installed kubernetes-mcp-server!"
    else
        warn "⚠️  Failed to install kubernetes-mcp-server."
    fi
else
    warn "⚠️  Skipping kubernetes-mcp-server installation because temporary directory is unavailable."
fi

# gitea-mcp is released on gitea.com rather than GitHub; verify against the
# release checksums before installing.
install_gitea_mcp() {
    local tag version arch asset base
    tag="$(curl -fsSL https://gitea.com/api/v1/repos/gitea/gitea-mcp/releases/latest \
        | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)" || return 1
    [[ -n "$tag" ]] || return 1
    version="${tag#v}"
    case "$(uname -m)" in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) return 1 ;;
    esac
    asset="gitea-mcp_Linux_${arch}.tar.gz"
    base="https://gitea.com/gitea/gitea-mcp/releases/download/${tag}"
    curl -fsSL -o "${TEMP_DIR}/${asset}" "${base}/${asset}" \
        && curl -fsSL -o "${TEMP_DIR}/gitea-mcp_${version}_checksums.txt" "${base}/gitea-mcp_${version}_checksums.txt" \
        && (cd "${TEMP_DIR}" && grep " ${asset}\$" "gitea-mcp_${version}_checksums.txt" | sha256sum -c --quiet -) \
        && tar -xzf "${TEMP_DIR}/${asset}" -C "${TEMP_DIR}" gitea-mcp \
        && install --mode=0755 "${TEMP_DIR}/gitea-mcp" "$HOME/.local/bin/gitea-mcp"
}

if [[ -n "${TEMP_DIR}" ]]; then
    if install_gitea_mcp; then
        info "🎉 Successfully installed gitea-mcp!"
    else
        warn "⚠️  Failed to install gitea-mcp."
    fi
else
    warn "⚠️  Skipping gitea-mcp installation because temporary directory is unavailable."
fi

# setup-mcp reads harness/config.yaml with mikefarah/yq. Debian and Ubuntu ship
# a different `yq` (kislyuk/yq), so install mikefarah's into ~/.local/bin
# unless the system already provides it.
is_mikefarah_yq() {
    [[ -x "$1" ]] && "$1" --version 2>/dev/null | grep -q 'mikefarah'
}

# yq's checksums file lists many hashes per asset; checksums_hashes_order
# names the columns.
install_yq() {
    local release tag arch asset base column expected
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv6l|armv7l) arch="arm" ;;
        i386|i686) arch="386" ;;
        loongarch64) arch="loong64" ;;
        riscv64|ppc64le|s390x) arch="$(uname -m)" ;;
        *) warn "⚠️  No yq build for architecture $(uname -m)."; return 1 ;;
    esac
    release="$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest)" || return 1
    tag="$(grep -m1 '"tag_name"' <<< "$release" | cut -d'"' -f4)"
    [[ -n "$tag" ]] || return 1
    asset="yq_${LOCAL_OS}_${arch}"
    base="https://github.com/mikefarah/yq/releases/download/${tag}"
    info "🔗 Downloading yq ${tag} for ${LOCAL_OS}/${arch}..."
    curl -fsSL -o "${TEMP_DIR}/${asset}" "${base}/${asset}" \
        && curl -fsSL -o "${TEMP_DIR}/yq_checksums" "${base}/checksums" \
        && curl -fsSL -o "${TEMP_DIR}/yq_checksums_order" "${base}/checksums_hashes_order" \
        || return 1
    column="$(grep -nx 'SHA-256' "${TEMP_DIR}/yq_checksums_order" | cut -d: -f1)"
    [[ -n "$column" ]] || { warn "⚠️  yq checksums don't list SHA-256."; return 1; }
    expected="$(awk -v a="$asset" -v c="$((column + 1))" '$1 == a { print $c }' "${TEMP_DIR}/yq_checksums")"
    [[ -n "$expected" ]] || { warn "⚠️  No yq checksum for ${asset}."; return 1; }
    (cd "${TEMP_DIR}" && printf '%s  %s\n' "$expected" "$asset" | sha256sum -c --quiet -) || return 1
    chmod 0755 "${TEMP_DIR}/${asset}"
    is_mikefarah_yq "${TEMP_DIR}/${asset}" \
        || { warn "⚠️  The downloaded yq doesn't run on this machine."; return 1; }
    install --mode=0755 "${TEMP_DIR}/${asset}" "$HOME/.local/bin/yq"
}

if is_mikefarah_yq /usr/bin/yq || is_mikefarah_yq /usr/local/bin/yq; then
    info "✅ mikefarah/yq is provided by the system."
elif [[ -n "${TEMP_DIR}" ]]; then
    if install_yq; then
        info "🎉 Successfully installed yq!"
    else
        warn "⚠️  Failed to install yq; setup-mcp can't update the agent MCP configs without it."
    fi
else
    warn "⚠️  Skipping yq installation because temporary directory is unavailable."
fi

dotfilesrc_var() {
    [[ -f "${HOME}/.dotfilesrc" ]] || return 0
    (. "${HOME}/.dotfilesrc" >/dev/null 2>&1; printf '%s' "${!1:-}")
}

GITEA_HOST="${GITEA_HOST:-$(dotfilesrc_var GITEA_HOST)}"
GRAFANA_URL="${GRAFANA_URL:-$(dotfilesrc_var GRAFANA_URL)}"

has_gitea_token() {
    [[ -n "$(secret-tool lookup service gitea-mcp url "${GITEA_HOST}" 2>/dev/null)" ]]
}

has_grafana_key() {
    grep -qE '^GRAFANA_SERVICE_ACCOUNT_TOKEN=.+' "${HOME}/.config/mcp/mcp-grafana.env" 2>/dev/null \
        || grep -qE '"GRAFANA_API_KEY"[[:space:]]*:[[:space:]]*"[^"]+"' "${HOME}/.copilot/mcp-config.json" 2>/dev/null
}

if ! has_cmd secret-tool; then
    warn "⚠️  secret-tool is not installed, so the gitea-mcp token can't be checked or read."
    warn "   Install libsecret's command-line tools with your package manager:"
    warn "   Arch/CachyOS: sudo pacman -S libsecret    Debian/Ubuntu: sudo apt install libsecret-tools"
elif [[ -z "${GITEA_HOST}" ]]; then
    warn "⚠️  Set GITEA_HOST in ~/.dotfilesrc so gitea-mcp knows which Gitea server to use."
elif ! has_gitea_token; then
    warn "⚠️  Remember to store the Gitea token for gitea-mcp in the keyring:"
    warn "   secret-tool store --label='gitea-mcp token' service gitea-mcp url ${GITEA_HOST}"
fi

if ! has_grafana_key; then
    warn "⚠️  Remember to add GRAFANA_SERVICE_ACCOUNT_TOKEN to ~/.config/mcp/mcp-grafana.env (setup-mcp prompts for it)"
    warn "   Generate it at: ${GRAFANA_URL:-your Grafana} → Administration → Service Accounts → Add service account token"
fi

if [[ "$(uname -o)" = "Android" ]]; then
    info "Krew seems to blow up on Android, skipping."
else
    if has_cmd kubectl && kubectl krew version >/dev/null 2>&1; then
        info "Krew is already installed. Upgrading Krew..."
        kubectl krew update || warn "⚠️  Failed to refresh Krew plugin index."
        krew_upgrade_out=$(kubectl krew upgrade krew 2>&1)
        krew_upgrade_rc=$?
        if [[ ${krew_upgrade_rc} -ne 0 ]] && ! grep -qi "already installed\|already up.to.date" <<< "${krew_upgrade_out}"; then
            warn "⚠️  Failed to upgrade Krew: ${krew_upgrade_out}"
        fi
    elif [[ -n "${TEMP_DIR}" ]]; then
        if download_latest_release "kubernetes-sigs/krew" "krew" "tar.gz" \
            && extract_download "krew" "tar.gz"; then
            # shellcheck disable=SC2211
            if "${TEMP_DIR}"/krew-* install krew; then
                info "🎉 Successfully installed Krew!"
            else
                warn "⚠️  Failed to install Krew."
            fi
        else
            warn "⚠️  Could not download or extract Krew."
        fi
    else
        warn "⚠️  Skipping Krew installation because temporary directory is unavailable."
    fi

    if has_cmd kubectl && kubectl krew version >/dev/null 2>&1; then
        if [[ -n "${HAVE_GUM}" ]]; then
            if gum spin --show-error --title="Installing Krew plugins..." -- \
                kubectl krew install blame iexec neat view-secret stern grep konfig ktop node-shell nsenter pv-migrate rename-pvc sniff; then
                info "🎉 Successfully installed Krew plugins!"
            else
                warn "⚠️  Failed to install one or more Krew plugins."
            fi
        else
            info "Installing Krew plugins..."
            kubectl krew install blame iexec neat view-secret stern grep konfig ktop node-shell nsenter pv-migrate rename-pvc sniff \
                >/dev/null 2>&1 || warn "⚠️  Failed to install one or more Krew plugins."
        fi
    elif has_cmd kubectl; then
        warn "⚠️  Krew is not available after install/upgrade step. Skipping Krew plugin installation."
    else
        warn "⚠️  kubectl is not installed. Skipping Krew plugin installation."
    fi
fi

if [[ -n "${HAVE_GUM}" ]]; then
    if gum spin --show-error --title="Installing Starship..." -- \
        bash -c "curl -fsSL https://starship.rs/install.sh | sh -s -- --bin-dir '${HOME}/.local/bin' --yes"; then
        info "🎉 Successfully installed Starship!"
    else
        warn "⚠️  Failed to install Starship."
    fi
else
    info "Installing Starship..."
    if curl -fsSL https://starship.rs/install.sh | sh -s -- --bin-dir "${HOME}/.local/bin" --yes >/dev/null 2>&1; then
        info "🎉 Successfully installed Starship!"
    else
        warn "⚠️  Failed to install Starship."
    fi
fi

info "Linking dotfiles..."
for EACH in "${SCRIPTPATH}"/dotfiles/*; do
    if [[ -f "${EACH}" ]]; then
        ln -sf "${EACH}" ~/".$(basename "${EACH}")"
    fi
done

info "Linking local binaries and scripts..."
ln -sf "${SCRIPTPATH}/kubeseal-interactive" "${HOME}/.local/bin/kubeseal-interactive"

for EACH in "${SCRIPTPATH}"/scripts/*; do
    if [[ -f "${EACH}" ]]; then
        ln -sf "${EACH}" ~/.local/bin/"$(basename "${EACH%.*}")"
    fi
done

# agent-dev picks its agent harness from the name it's run as.
for HARNESS in opencode claude copilot; do
    ln -sf "${SCRIPTPATH}/scripts/agent-dev.sh" "${HOME}/.local/bin/${HARNESS}-dev"
done

# Link a dotfiles file or directory to a harness config path, leaving a real
# file or directory there alone.
link_harness_file() {
    local src="$1" dest="$2"
    if [[ -e "${dest}" && ! -L "${dest}" ]]; then
        warn "⚠️  ${dest} exists and isn't a link; not replacing it."
        return 0
    fi
    mkdir -p "$(dirname "${dest}")"
    ln -sfn "${src}" "${dest}"
}

# Skills: Claude Code reads ~/.claude/skills, and OpenCode reads that directory
# too, so it gets no links of its own (they would duplicate the shared ones).
# Copilot CLI reads ~/.copilot/skills. agent-dev mounts the same directory into
# its agent containers.
COPILOT_DIR="${COPILOT_HOME:-${HOME}/.copilot}"
SKILL_DIRS=("${HOME}/.claude/skills")
[[ -d "${COPILOT_DIR}" ]] && SKILL_DIRS+=("${COPILOT_DIR}/skills")
info "Linking agent skills..."
for EACH in "${SCRIPTPATH}"/skills/*/; do
    for SKILL_DIR in "${SKILL_DIRS[@]}"; do
        link_harness_file "${EACH%/}" "${SKILL_DIR}/$(basename "${EACH}")"
    done
done

# Global instructions, when harness/user-instructions.md exists. OpenCode reads
# ~/.claude/CLAUDE.md when ~/.config/opencode/AGENTS.md doesn't exist.
HARNESS_INSTRUCTIONS="${SCRIPTPATH}/harness/user-instructions.md"
if [[ -f "${HARNESS_INSTRUCTIONS}" ]]; then
    info "Linking agent instructions..."
    link_harness_file "${HARNESS_INSTRUCTIONS}" "${HOME}/.claude/CLAUDE.md"
    [[ -d "${COPILOT_DIR}" ]] \
        && link_harness_file "${HARNESS_INSTRUCTIONS}" "${COPILOT_DIR}/copilot-instructions.md"
    [[ -e "${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/AGENTS.md" ]] \
        && warn "⚠️  ~/.config/opencode/AGENTS.md exists, so OpenCode won't read the shared instructions."
fi

# Remove links to dotfiles that moved or were deleted, and the old links in
# OpenCode's own skills directory, which would duplicate the shared ones.
HARNESS_LINKS=("${XDG_CONFIG_HOME:-${HOME}/.config}"/opencode/skills/*
    "${HOME}/.claude/CLAUDE.md" "${COPILOT_DIR}/copilot-instructions.md")
for SKILL_DIR in "${SKILL_DIRS[@]}"; do
    HARNESS_LINKS+=("${SKILL_DIR}"/*)
done
for EACH in "${HARNESS_LINKS[@]}"; do
    [[ -L "${EACH}" && "$(readlink "${EACH}")" == "${SCRIPTPATH}"/* ]] || continue
    if [[ "${EACH}" == */opencode/skills/* || ! -e "${EACH}" ]]; then
        rm -f "${EACH}"
    fi
done

if has_cmd noctalia; then
    info "Installing Noctalia lock hooks..."
    for EACH in wpctl pw-dump jq; do
        has_cmd "${EACH}" || warn "⚠️  ${EACH} not found; muting audio on lock won't work."
    done
    mkdir -p "${HOME}/.config/noctalia/hooks"
    ln -sf "${SCRIPTPATH}/noctalia/lock-audio-hooks.toml" \
        "${HOME}/.config/noctalia/zz-dotfiles-lock-audio.toml"
    ln -sf "${SCRIPTPATH}/noctalia/hooks/lock-audio.sh" \
        "${HOME}/.config/noctalia/hooks/lock-audio.sh"
    noctalia msg config-reload >/dev/null 2>&1 \
        || warn "⚠️  Noctalia config reload failed; restart Noctalia to apply lock hooks."
else
    info "Noctalia not found; skipping Noctalia lock hooks."
fi

if has_cmd Hyprland || has_cmd hyprctl; then
    info "Hyprland detected; keeping it out of swap..."
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        warn "⚠️  systemd user session unavailable. Skipping Hyprland swap protection."
    elif systemctl --user is-active --quiet wayland-wm@hyprland.desktop.service; then
        systemctl --user set-property wayland-wm@hyprland.desktop.service MemorySwapMax=0 MemoryMin=512M \
            || warn "⚠️  Failed to set Hyprland swap protection."
    else
        HYPR_DROPIN="${HOME}/.config/systemd/user.control/wayland-wm@hyprland.desktop.service.d"
        mkdir -p "${HYPR_DROPIN}"
        printf '[Service]\nMemorySwapMax=0\n' > "${HYPR_DROPIN}/50-MemorySwapMax.conf"
        printf '[Service]\nMemoryMin=512M\n' > "${HYPR_DROPIN}/50-MemoryMin.conf"
        systemctl --user daemon-reload || warn "⚠️  Failed to reload systemd user units."
    fi

    # Only config/ is linked: HyprMon, Noctalia and the Hyprland Settings
    # panel write the other files under ~/.config/hypr, including hyprland.lua.
    info "Linking Hyprland config..."
    rm -Rf "${HOME}/.config/hypr/config"
    mkdir -p "${HOME}/.config/hypr"
    ln -sfn "${SCRIPTPATH}/hypr/config" "${HOME}/.config/hypr/config"

    HYPR_MAIN="${HOME}/.config/hypr/hyprland.lua"
    HYPR_REQUIRE='require("config.dotfiles")'
    if [[ ! -f "${HYPR_MAIN}" ]]; then
        warn "⚠️  ${HYPR_MAIN} not found; add ${HYPR_REQUIRE} to your Hyprland config."
    elif ! grep -qxF "${HYPR_REQUIRE}" "${HYPR_MAIN}"; then
        # config.dotfiles loads these, so drop any copies added by hand.
        if grep -qxF 'require("config.groups")' "${HYPR_MAIN}"; then
            sed -i \
                -e 's/^require("config\.groups")$/'"${HYPR_REQUIRE}"'/' \
                -e '/^require("config\.user")$/d' \
                "${HYPR_MAIN}"
        else
            sed -i '/^require("config\.user")$/d' "${HYPR_MAIN}"
            printf '\n%s\n' "${HYPR_REQUIRE}" >> "${HYPR_MAIN}"
        fi
    fi
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        hyprctl reload >/dev/null || warn "⚠️  Hyprland config reload failed."
    fi
fi

echo "Installing Oh-My-Tmux..."
if has_cmd tmux; then
    if [[ -f "$(pwd)/oh-my-tmux/.tmux.conf" ]]; then
        ln -sf "$(pwd)"/oh-my-tmux/.tmux.conf "${HOME}/.tmux.conf" || warn "⚠️  Failed to link .tmux.conf"
    else
        warn "⚠️  Skipping Oh-My-Tmux setup because submodule files are missing."
    fi
else
    warn "⚠️  Skipping Oh-My-Tmux setup because tmux is unavailable."
fi

if [[ -n "${HAVE_ZSH}" ]]; then
    if [[ -d "${HOME}/.oh-my-zsh" ]]; then
        info "Oh-My-ZSH already installed."
        if [[ -n "${ZSH_VERSION}" ]] && type omz &>/dev/null 2>&1; then
            info "Running Oh-My-ZSH update..."
            omz update || warn "⚠️  Oh-My-ZSH update failed."
        else
            info "ℹ️  omz not available in this shell session. Skipping update."
        fi
    else
        echo "Installing Oh-My-ZSH..."
        sh -c "$(RUNZSH=no curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || \
            warn "⚠️  Oh-My-ZSH installation failed."
    fi
fi

echo "Installing Bash-it..."
if [[ -d "${HOME}/.bash_it" ]]; then
    info "Bash-it already installed."
elif has_cmd git; then
    git clone --depth=1 https://github.com/Bash-it/bash-it.git "${HOME}/.bash_it" || \
        warn "⚠️  Bash-it installation failed."
else
    warn "⚠️  git is unavailable. Skipping Bash-it installation."
fi

if [[ -x "${HOME}/.local/bin/cmctl" ]]; then
    info "Installing cert-manager CLI (cmctl) completions..."
    if [[ -n "${HAVE_ZSH}" ]] && [[ -d "${HOME}/.oh-my-zsh" ]]; then
        CMCTL_ZSH_DIR="${HOME}/.oh-my-zsh/cache/completions"
        if ! { mkdir -p "${CMCTL_ZSH_DIR}" \
            && "${HOME}/.local/bin/cmctl" completion zsh > "${CMCTL_ZSH_DIR}/_cmctl"; }; then
            warn "⚠️  Failed to install cmctl zsh completions."
        fi
    fi
    CMCTL_BASH_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions"
    if ! { mkdir -p "${CMCTL_BASH_DIR}" \
        && "${HOME}/.local/bin/cmctl" completion bash > "${CMCTL_BASH_DIR}/cmctl"; }; then
        warn "⚠️  Failed to install cmctl bash completions."
    fi
fi

if [[ -z "${IN_DEVCONTAINER}" ]] && has_cmd vim && has_cmd git; then
    echo "Installing Vim configuration (replacing any existing ~/.vim)..."
    rm -Rf "${HOME}/.vim" "${HOME}/.vimrc" "${HOME}/.vimrc.local" "${HOME}/.vimrc.local.bundles"
    mkdir -p "${HOME}/.vim/pack/plugins/start"
    for VIM_PLUGIN in \
        https://github.com/github/copilot.vim.git \
        https://github.com/sheerun/vim-polyglot.git \
        https://github.com/editorconfig/editorconfig-vim.git; do
        git clone --depth=1 "${VIM_PLUGIN}" "${HOME}/.vim/pack/plugins/start/$(basename "${VIM_PLUGIN}" .git)" \
            >/dev/null 2>&1 || warn "⚠️  Failed to clone Vim plugin ${VIM_PLUGIN}."
    done
fi

info "Creating Python Virtual Environment..."
if [[ -n "${HAVE_PYTHON_VENV}" ]]; then
    if ! python3 -m venv "${HOME}/.venv" >/dev/null 2>&1; then
        warn "⚠️  Failed to create Python virtual environment."
    elif [[ -z "${IN_DEVCONTAINER}" ]]; then
        info "Installing djlint into the Python virtual environment..."
        "${HOME}/.venv/bin/pip" install --quiet --upgrade "djlint==1.49.2" \
            || warn "⚠️  Failed to install djlint into ~/.venv."
    fi
else
    warn "⚠️  Skipping Python virtual environment creation."
fi

echo "Cleaning up Powerlevel10k artifacts..."
rm -f "${HOME}/.p10k.zsh"
rm -f "${HOME}"/.cache/p10k-instant-prompt-*.zsh 2>/dev/null || true
if [[ -L "${HOME}/.oh-my-zsh/custom/themes/powerlevel10k" ]]; then
    rm -f "${HOME}/.oh-my-zsh/custom/themes/powerlevel10k"
fi

info "Linking files..."
if [[ -n "${HAVE_ZSH}" ]]; then
    touch "${HOME}/.zsh_history"
    ln -sf "${SCRIPTPATH}/zshrc" ~/.zshrc
fi

touch "${HOME}/.bash_history"
ln -sf "${SCRIPTPATH}/bashrc" ~/.bashrc

mkdir -p "${HOME}/.config"
bash "${SCRIPTPATH}/scripts/render-starship.sh"

if [[ -z "${IN_DEVCONTAINER}" ]] && has_cmd vim; then
    ln -sf "${SCRIPTPATH}/vim/vimrc" ~/.vimrc
fi

if [[ -z "${IN_DEVCONTAINER}" ]] && has_cmd nvim; then
    rm -Rf "${HOME}/.config/nvim"
    ln -sfn "${SCRIPTPATH}/nvim" "${HOME}/.config/nvim"
fi

if [[ -n "${HAVE_ZSH}" ]]; then
    echo "Linking Oh-My-ZSH Plugins and Themes..."
    if [[ -d "${SCRIPTPATH}/oh-my-zsh/plugins" ]] && [[ -d "${SCRIPTPATH}/oh-my-zsh/themes" ]]; then
        if [[ -d "${HOME}/.oh-my-zsh/custom" ]]; then
            for PLUGIN in "${SCRIPTPATH}"/oh-my-zsh/plugins/*; do
                ln -sf "${PLUGIN}" ~/.oh-my-zsh/custom/plugins/"$(basename "${PLUGIN}")"
            done
            for THEME in "${SCRIPTPATH}"/oh-my-zsh/themes/*; do
                ln -sf "${THEME}" ~/.oh-my-zsh/custom/themes/"$(basename "${THEME}")"
            done
        else
            warn "⚠️  ~/.oh-my-zsh/custom is missing. Skipping custom plugin/theme linking."
        fi
    else
        warn "⚠️  Local oh-my-zsh plugin/theme files are missing. Skipping plugin/theme linking."
    fi
fi

if [[ -z "${IN_DEVCONTAINER}" ]]; then
    if has_cmd nvim; then
        nvim_version="$(nvim --version | head -n1 | sed -E 's/^NVIM v([0-9]+\.[0-9]+).*/\1/')"
        if [[ "$(printf '%s\n' 0.11 "${nvim_version}" | sort -V | head -n1)" != "0.11" ]]; then
            warn "⚠️  Neovim ${nvim_version:-unknown} is too old. Neovim 0.11 or newer is required."
        fi

        echo "Installing Neovim plugins at the versions in lazy-lock.json..."
        NVIM_PARSER_CMD="lua require('nvim-treesitter').install(require('config.parsers')):wait(600000)"
        if [[ -n "${HAVE_GUM}" ]]; then
            gum spin --show-error --title="Installing Neovim plugins and parsers..." -- \
                sh -c 'nvim --headless "+Lazy! install" "+Lazy! restore" +qa && nvim --headless "+'"${NVIM_PARSER_CMD}"'" +qa' \
                || warn "⚠️  Neovim plugin install failed. Open nvim to retry."
        else
            { nvim --headless "+Lazy! install" "+Lazy! restore" +qa && nvim --headless "+${NVIM_PARSER_CMD}" +qa; } >/dev/null 2>&1 \
                || warn "⚠️  Neovim plugin install failed. Open nvim to retry."
        fi
    else
        warn "⚠️  nvim is not installed. Install Neovim 0.11 or newer for the Neovim config."
    fi

    for TOOL in rg fzf node tree-sitter stylua shfmt yamlfmt ruff djlint shellcheck; do
        if ! has_cmd "${TOOL}"; then
            warn "⚠️  ${TOOL} is not on PATH. Neovim needs it for search, formatting, parsing, or linting; install it with your package manager."
        fi
    done

    if ! has_cmd cc && ! has_cmd gcc && ! has_cmd clang; then
        warn "⚠️  No C compiler (cc, gcc, or clang) found. nvim-treesitter needs one to build parsers. Install build tools (base-devel on Arch, build-essential on Ubuntu)."
    fi
fi

popd &>/dev/null || exit

if [[ -x "${SCRIPTPATH}/scripts/setup-mcp.sh" ]]; then
    info "Setting up MCP servers (systemd user units + OpenCode, Claude and Copilot configs)..."
    "${SCRIPTPATH}/scripts/setup-mcp.sh" || warn "⚠️  MCP setup completed with warnings."
fi

if [[ -x "${SCRIPTPATH}/scripts/setup-lint.sh" ]]; then
    info "Setting up linters (container-based)..."
    "${SCRIPTPATH}/scripts/setup-lint.sh" || warn "⚠️  Linter setup completed with warnings."
fi

SYSTEM_ARGS=()
if has_battery && is_physical_device; then
    SYSTEM_ARGS+=("--power")
fi

if has_cmd ufw; then
    SYSTEM_ARGS+=("--ufw")
fi

if has_cmd docker; then
    SYSTEM_ARGS+=("--docker")
fi

if [[ ${#SYSTEM_ARGS[@]} -gt 0 ]]; then
    system_status=0
    "${SCRIPTPATH}/install-system.sh" "${SYSTEM_ARGS[@]}" || system_status=$?
    if [[ "${system_status}" -eq 10 ]]; then
        info "Installing system files (needs root)..."
        if sudo -p "[sudo] password for %u to install system files (power profiles, ufw rules and docker refresh for MCP servers): " \
            "${SCRIPTPATH}/install-system.sh" "${SYSTEM_ARGS[@]}"; then
            info "🎉 Successfully installed system files!"
        else
            warn "⚠️  System files were not installed."
        fi
    elif [[ "${system_status}" -ne 0 ]]; then
        warn "⚠️  System file check failed."
    fi
fi

echo "🎉 Successfully completed dotfiles installation!"
