#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
HAVE_GUM=""
TEMP_DIR=""
PATH="${HOME}"/.local/bin:"${PATH}"

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

warn "⚠️  Remember to store the Gitea token for gitea-mcp in the keyring:"
warn "   secret-tool store --label='gitea-mcp token' service gitea-mcp url https://git.gaea.mythicnet.org"

warn "⚠️  Remember to add GRAFANA_API_KEY to ~/.copilot/mcp-config.json"
warn "   Generate it at: https://metrics.gaea.mythicnet.org → Administration → Service Accounts → Add service account token"

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

        echo "Syncing Neovim plugins..."
        if [[ -n "${HAVE_GUM}" ]]; then
            gum spin --show-error --title="Syncing Neovim plugins..." -- \
                nvim --headless "+Lazy! sync" +qa || warn "⚠️  Neovim plugin sync failed."
        else
            nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1 || warn "⚠️  Neovim plugin sync failed."
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
    info "Setting up MCP servers (systemd user units + OpenCode config)..."
    "${SCRIPTPATH}/scripts/setup-mcp.sh" || warn "⚠️  MCP setup completed with warnings."
fi

if [[ -x "${SCRIPTPATH}/scripts/setup-lint.sh" ]]; then
    info "Setting up linters (container-based)..."
    "${SCRIPTPATH}/scripts/setup-lint.sh" || warn "⚠️  Linter setup completed with warnings."
fi

if has_cmd ufw; then
    warn "⚠️  ufw detected: run '${SCRIPTPATH}/mcp/mcp-firewall.sh' to allow the MCP server ports (8180, 8280) from the docker bridge network only."
fi

echo "🎉 Successfully completed dotfiles installation!"
