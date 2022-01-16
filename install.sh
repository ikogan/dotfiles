#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

pushd "${SCRIPTPATH}" &>/dev/null || exit

git submodule update --recursive --remote --init

echo "Installing custom binaries..."
if [[ ! -d "${HOME}/.bin" ]]; then
    mkdir "${HOME}/.bin"
fi

for BINARY in "${SCRIPTPATH}"/binaries/*; do
    ln -svf "${BINARY}" ~/.bin/"$(basename "${BINARY}")"
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
