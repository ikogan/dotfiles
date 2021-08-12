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

echo "Linking Oh-My-ZSH Plugins and Themes..."
for PLUGIN in "${SCRIPTPATH}"/oh-my-zsh/plugins/*; do
    ln -svf "${PLUGIN}" ~/.oh-my-zsh/custom/plugins/"$(basename "${PLUGIN}")"
done
for THEME in "${SCRIPTPATH}"/oh-my-zsh/themes/*; do
    ln -svf "${THEME}" ~/.oh-my-zsh/custom/themes/"$(basename "${THEME}")"
done

echo "Installing all NeoBundles..."
"${HOME}/.vim/bundle/neobundle.vim/bin/neoinstall"

popd &>/dev/null || exit
