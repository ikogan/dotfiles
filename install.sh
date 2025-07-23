#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
HAVE_GUM="$(which gum 2>/dev/null && 'true')"
TEMP_DIR=$(mktemp -d)

pushd "${SCRIPTPATH}" &>/dev/null || exit

git submodule update --recursive --remote --init

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
            if which yq &>/dev/null; then
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
            info -e "🔗 Downloading checksums..."
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

if ! which which &>/dev/null; then
    error "The 'which' command is missing. Please install it first." 1>&2
    exit 1
fi

if [[ -z "$(which tmux 2>/dev/null)" ]]; then
    error "Tmux is needed for some things, please install it." 1>&2
    exit 1
fi

if ! python3 -c 'import ensurepip' &>/dev/null; then
    error "Python 3 Pip and VirtualEnv are needed for some things, please install python3-venv" 1>&2
    exit 1
fi

if [[ "$(uname -o)" = "Android" ]]; then
  test -d "${HOME}/.tmp" || mkdir "${HOME}/.tmp"
  TEMP_DIR=$(mktemp -d "${HOME}/.tmp/dotfiles.XXXXX") || exit 1
else
  TEMP_DIR=$(mktemp -d /tmp/dotfiles.XXXXX) || exit 1
fi

if [[ ! -d "${TEMP_DIR}" ]]; then
    error "Error: Could not create temporary directory." 1>&2
    exit 1
fi

if [[ ! "${TEMP_DIR}" = /tmp/dotfiles.* ]] && [[ ! "${TEMP_DIR}" = "${HOME}"/.tmp/dotfiles.* ]]; then
    error "Error: Temporary directory is weird: ${TEMP_DIR}." 1>&2
    exit 1
fi

trap 'rm -Rf "${TEMP_DIR:?}"' EXIT

info "Installing for ${LOCAL_OS} on ${LOCAL_ARCH[*]}..."

info "Installing custom binaries..."
if [[ ! -d "${HOME}/.local/bin" ]]; then
    mkdir "${HOME}/.local/bin"
fi

download_latest_release "charmbracelet/gum" "gum" "tar.gz" || exit 1
extract_download "gum" "tar.gz" || exit 1
install --mode=0755 "${TEMP_DIR}/gum"*/"gum" "$HOME/.local/bin/gum" || exit 1
info "🎉 Successfully installed gum!"

HAVE_GUM="true"

download_latest_release "cantino/mcfly" "mcfly" "tar.gz" || exit 1
extract_download "mcfly" "tar.gz" || exit 1
install --mode=0755 "${TEMP_DIR}"/mcfly "${HOME}/.local/bin"
info "🎉 Successfully installed McFly!"

if [[ "$(uname -o)" = "Android" ]]; then
    info "Krew seems to blow up on Android, skipping."
else
    download_latest_release "kubernetes-sigs/krew" "krew" "tar.gz" || exit 1
    extract_download "krew" "tar.gz" || exit 1
    # shellcheck disable=SC2211
    "${TEMP_DIR}"/krew-* install krew
    info "🎉 Successfully installed Krew!"

    info "Installing Krew plugins..."
    kubectl krew install neat view-secret stern grep konfig ktop node-shell nsenter pv-migrate rename-pvc sniff
fi

echo "Linking dotfiles..."
for EACH in "${SCRIPTPATH}"/dotfiles/*; do
    if [[ -f "${EACH}" ]]; then
        ln -svf "${EACH}" ~/".$(basename "${EACH}")"
    fi
done

echo "Installing Oh-My-Tmux..."
ln -s "$(pwd)"/oh-my-tmux/.tmux.conf "${HOME}/.tmux.conf"

echo "Installing Oh-My-ZSH..."
sh -c "$(RUNZSH=no curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

if [[ -d "${HOME}/.vim" ]]; then
    echo "  Cleaning up existing vim configuration..."
    rm -Rf "${HOME}/.vim/*"
fi

if which vim &>/dev/null; then
    echo "Installing NeoBundle..."
    sh -c "$(curl https://raw.githubusercontent.com/Shougo/neobundle.vim/master/bin/install.sh)" "" --unattended
fi

echo "Creating Python Virtual Environment..."
python3 -m venv "${HOME}/.venv"
"${HOME}"/.venv/bin/python3 -m pip install --upgrade habitipy

echo "Linking files..."
touch "${HOME}/.zsh_history"
ln -svf "${SCRIPTPATH}/zshrc" ~/.zshrc
ln -svf "${SCRIPTPATH}/p10k.zsh" ~/.p10k.zsh

if which vim &>/dev/null; then
    ln -svf "${SCRIPTPATH}/vim/vimrc" ~/.vimrc
    ln -svf "${SCRIPTPATH}/vim/vimrc.local" ~/.vimrc.local
    ln -svf "${SCRIPTPATH}/vim/vimrc.local.bundles" ~/.vimrc.local.bundles
fi

echo "Linking Oh-My-ZSH Plugins and Themes..."
for PLUGIN in "${SCRIPTPATH}"/oh-my-zsh/plugins/*; do
    ln -svf "${PLUGIN}" ~/.oh-my-zsh/custom/plugins/"$(basename "${PLUGIN}")"
done
for THEME in "${SCRIPTPATH}"/oh-my-zsh/themes/*; do
    ln -svf "${THEME}" ~/.oh-my-zsh/custom/themes/"$(basename "${THEME}")"
done

if which vim &>/dev/null; then
    echo "Installing all NeoBundles..."
    "${HOME}/.vim/bundle/neobundle.vim/bin/neoinstall"
fi

popd &>/dev/null || exit
