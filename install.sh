#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

pushd "${SCRIPTPATH}" &>/dev/null || exit

git submodule update --recursive --remote --init

# From https://gist.github.com/lukechilds/a83e1d7127b78fef38c2914c4ececc3c
get_latest_release() {
  curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
    grep '"tag_name":' |                                            # Get tag line
    sed -E 's/.*"([^"]+)".*/\1/'                                    # Pluck JSON value
}

OS_KERNEL="$(uname -s)"
CPU_ARCHITECTURE="$(uname -m)"
CPU_ARCHITECTURE_LEGACY=""
case ${CPU_ARCHITECTURE} in
    i386 | i686)   CPU_ARCHITECTURE_LEGACY="386" ;;
    x86_64)        CPU_ARCHITECTURE_LEGACY="amd64" ;;
    *) CPU_ARCHITECTURE_LEGACY=${CPU_ARCHITECTURE} ;;
esac

if [[ -z "$(which kubectl 2>/dev/null)" ]]; then
    if [[ -e "${HOME}/.local/state/vs-kubernetes/tools/kubectl/kubectl" ]]; then
        export PATH=$PATH:"${HOME}/.local/state/vs-kubernetes/tools/kubectl"
    else
        echo "Kubectl is necessary for some of this script, please install it first." 1>&2
        exit 1
    fi
fi

TEMP_DIR=$(mktemp -d /tmp/dotfiles.XXXXX) || exit 1

if [[ ! -d "${TEMP_DIR}" ]]; then
    echo "Error: Could not create temporary directory." 1>&2
    exit 1
fi

if [[ ! "${TEMP_DIR}" = /tmp/dotfiles.* ]]; then
    echo "Error: Temproary directory is weird: ${TEMP_DIR}." 1>&2
    exit 1
fi

trap 'rm -Rf "${TEMP_DIR:?}"' EXIT

echo "Installing custom binaries..."
if [[ ! -d "${HOME}/.bin" ]]; then
    mkdir "${HOME}/.bin"
fi

echo "Installing McFly..."
PACKAGE_VERSION=$(get_latest_release cantino/mcfly)
curl -o "${TEMP_DIR}/package.tar.gz" -L https://github.com/cantino/mcfly/releases/download/"${PACKAGE_VERSION}"/mcfly-"${PACKAGE_VERSION}"-"${CPU_ARCHITECTURE}"-unknown-"${OS_KERNEL}"-musl.tar.gz
tar -C "${TEMP_DIR}" -zxvf "${TEMP_DIR}/package.tar.gz"
install "${TEMP_DIR}"/mcfly "${HOME}/.bin"
rm -Rf "${TEMP_DIR:?}/*"

echo "Installing Kubecolor..."
PACKAGE_VERSION=$(get_latest_release hidetatz/kubecolor)
curl -o "${TEMP_DIR}/package.tar.gz" -L https://github.com/hidetatz/kubecolor/releases/download/"${PACKAGE_VERSION}"/kubecolor_"$(echo "${PACKAGE_VERSION}" | sed -r "s/v([0-9\.]+)/\1/")"_"${OS_KERNEL}"_"${CPU_ARCHITECTURE}".tar.gz
tar -C "${TEMP_DIR}" -zxvf "${TEMP_DIR}/package.tar.gz"
install "${TEMP_DIR}"/kubecolor "${HOME}/.bin"
rm -Rf "${TEMP_DIR:?}/*"

echo "Installing k9s..."
PACKAGE_VERSION=$(get_latest_release derailed/k9s)
curl -o "${TEMP_DIR}/package.tar.gz" -L https://github.com/derailed/k9s/releases/download/"${PACKAGE_VERSION}"/k9s_"${OS_KERNEL}"_"${CPU_ARCHITECTURE}".tar.gz
tar -C "${TEMP_DIR}" -zxvf "${TEMP_DIR}/package.tar.gz"
install "${TEMP_DIR}"/k9s "${HOME}/.bin"
rm -Rf "${TEMP_DIR:?}/*"

echo "Installing Krew..."
PACKAGE_VERSION=$(get_latest_release kubernetes-sigs/krew)
curl -o "${TEMP_DIR}/package.tar.gz" -L https://github.com/kubernetes-sigs/krew/releases/download/"${PACKAGE_VERSION}"/krew-"${OS_KERNEL}"_"${CPU_ARCHITECTURE_LEGACY}".tar.gz
tar -C "${TEMP_DIR}" -zxvf "${TEMP_DIR}/package.tar.gz"
chmod +x "${TEMP_DIR}"/krew-*
# shellcheck disable=SC2211
"${TEMP_DIR}"/krew-* install krew

echo "Installing Krew plugins..."
kubectl krew install neat view-secret stern grep konfig ktop node-shell nsenter pv-migrate rename-pvc sniff

echo "Linking dotfiles..."
for EACH in "${SCRIPTPATH}"/dotfiles/*; do
    if [[ -f "${EACH}" ]]; then
        ln -svf "${EACH}" ~/".$(basename "${EACH}")"
    fi
done

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
