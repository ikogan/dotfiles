#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

pushd "${SCRIPTPATH}" || exit &>/dev/null

git submodule update --recursive --remote --init

echo "Installing Oh-My-ZSH..."
sh -c "$(RUNZSH=no curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

if [[ -d "${HOME}/.vim" ]]; then
    echo "  Cleaning up existing vim configuration..."
    rm -Rf "${HOME}/.vim/*"
fi

echo "Installing NeoBundle..."
sh -c "$(curl https://raw.githubusercontent.com/Shougo/neobundle.vim/master/bin/install.sh)"

echo "Linking files..."
ln -svf "${SCRIPTPATH}/zshrc" ~/.zshrc
ln -svf "${SCRIPTPATH}/vim/vimrc" ~/.vimrc
ln -svf "${SCRIPTPATH}/vim/vimrc.local" ~/.vimrc.local
ln -svf "${SCRIPTPATH}/vim/vimrc.local.bundles" ~/.vimrc.local.bundles

if [[ -d "${HOME}/.oh-my-zsh/custom" && ! -L "${HOME}/.oh-my-zsh/custom" ]]; then
    rm -Rf "${HOME}/.oh-my-zsh/custom"
fi

ln -svf "${SCRIPTPATH}/oh-my-zsh" "${HOME}/.oh-my-zsh/custom"

echo "Installing all NeoBundles..."
"${HOME}/.vim/bundle/neobundle.vim/bin/neoinstall"

popd &>/dev/null || exit &>/dev/null
