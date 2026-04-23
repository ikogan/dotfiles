#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
HAVE_GUM=""
TEMP_DIR=$(mktemp -d)
PATH="${HOME}"/.local/bin:"${PATH}"

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_devcontainer() {
    [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${DEVCONTAINER:-}" ]] || [[ -n "${CODESPACES:-}" ]] || [[ -f "/.dockerenv" && -d "/workspaces" ]]
}

pushd "${SCRIPTPATH}" &>/dev/null || exit

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

    if ! has_cmd curl; then
        warn "⚠️  Skipping ${binary_name}: curl is not available."
        return 1
    fi

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

    if [[ "$(uname -o)" = "Android" ]]; then
        test -d "${HOME}/.tmp" || mkdir -p "${HOME}/.tmp"
        candidate=$(mktemp -d "${HOME}/.tmp/dotfiles.XXXXX" 2>/dev/null)
    else
        candidate=$(mktemp -d /tmp/dotfiles.XXXXX 2>/dev/null)
    fi

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

if has_cmd gh; then
    if gh extension list 2>/dev/null | grep -qE '(^|[[:space:]])github/gh-copilot([[:space:]]|$)'; then
        info "ℹ️  GitHub CLI Copilot extension already installed."
    else
        info "Installing GitHub CLI Copilot extension..."
        if gh extension install github/gh-copilot; then
            info "🎉 Successfully installed GitHub CLI Copilot extension!"
        else
            warn "⚠️  Failed to install GitHub CLI Copilot extension."
        fi
    fi
else
    warn "⚠️  gh is unavailable. Skipping GitHub CLI Copilot extension installation."
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

if has_cmd curl; then
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
else
    warn "⚠️  Skipping Starship installation because curl is unavailable."
fi

info "Linking dotfiles..."
for EACH in "${SCRIPTPATH}"/dotfiles/*; do
    if [[ -f "${EACH}" ]]; then
        ln -sf "${EACH}" ~/".$(basename "${EACH}")"
    fi
done

info "Linking local binaries..."
ln -sf "${SCRIPTPATH}/kubeseal-interactive" "${HOME}/.local/bin/kubeseal-interactive"

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
        if has_cmd curl; then
            sh -c "$(RUNZSH=no curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || \
                warn "⚠️  Oh-My-ZSH installation failed."
        else
            warn "⚠️  curl is unavailable. Skipping Oh-My-ZSH installation."
        fi
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

if [[ -z "${IN_DEVCONTAINER}" ]] && [[ -d "${HOME}/.vim" ]]; then
    echo "Cleaning up existing vim configuration..."
    rm -Rf "${HOME}/.vim/*"
fi

if [[ -z "${IN_DEVCONTAINER}" ]] && has_cmd vim; then
    echo "Installing NeoBundle..."
    if has_cmd curl; then
        if [[ -n "${HAVE_GUM}" ]]; then
            gum spin --show-error --title="Installing NeoBundle..." -- \
                sh -c "$(curl -fsSL https://raw.githubusercontent.com/Shougo/neobundle.vim/master/bin/install.sh)" "" --unattended || \
                warn "⚠️  NeoBundle install script failed."
        else
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/Shougo/neobundle.vim/master/bin/install.sh)" "" --unattended \
                >/dev/null 2>&1 || warn "⚠️  NeoBundle install script failed."
        fi
    else
        warn "⚠️  curl is unavailable. Skipping NeoBundle installation."
    fi
fi

info "Creating Python Virtual Environment..."
if [[ -n "${HAVE_PYTHON_VENV}" ]]; then
    if python3 -m venv "${HOME}/.venv" >/dev/null 2>&1; then
        "${HOME}"/.venv/bin/python3 -m pip install -q --upgrade habitipy || warn "⚠️  Failed to install habitipy in virtualenv."
    else
        warn "⚠️  Failed to create Python virtual environment."
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
ln -sf "${SCRIPTPATH}/starship.toml" "${HOME}/.config/starship.toml"

if [[ -z "${IN_DEVCONTAINER}" ]] && has_cmd vim; then
    ln -sf "${SCRIPTPATH}/vim/vimrc" ~/.vimrc
    ln -sf "${SCRIPTPATH}/vim/vimrc.local" ~/.vimrc.local
    ln -sf "${SCRIPTPATH}/vim/vimrc.local.bundles" ~/.vimrc.local.bundles
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

if [[ -z "${IN_DEVCONTAINER}" ]] && has_cmd vim; then
    echo "Installing all NeoBundles..."
    if [[ -x "${HOME}/.vim/bundle/neobundle.vim/bin/neoinstall" ]]; then
        if [[ -n "${HAVE_GUM}" ]]; then
            gum spin --show-error --title="Installing NeoBundle packages..." -- \
                "${HOME}/.vim/bundle/neobundle.vim/bin/neoinstall" || warn "⚠️  NeoBundle installation step failed."
        else
            "${HOME}/.vim/bundle/neobundle.vim/bin/neoinstall" \
                >/dev/null 2>&1 || warn "⚠️  NeoBundle installation step failed."
        fi
    else
        warn "⚠️  neoinstall not found. Skipping NeoBundle package install."
    fi
fi

popd &>/dev/null || exit
