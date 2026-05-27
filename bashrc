# shellcheck shell=bash

dotfiles_resolve_path() {
    local target="$1"
    local target_dir=""

    while [[ -L "${target}" ]]; do
        target_dir="$(cd -- "$(dirname -- "${target}")" >/dev/null 2>&1 && pwd -P)"
        target="$(readlink "${target}")"
        [[ "${target}" = /* ]] || target="${target_dir}/${target}"
    done

    target_dir="$(cd -- "$(dirname -- "${target}")" >/dev/null 2>&1 && pwd -P)"
    printf '%s\n' "${target_dir}/$(basename -- "${target}")"
}

export DOTFILES_SHELL='bash'
DOTFILES_BASHRC_PATH="$(dotfiles_resolve_path "${BASH_SOURCE[0]}")"
DOTFILES_ROOT="$(cd -- "$(dirname -- "${DOTFILES_BASHRC_PATH}")" >/dev/null 2>&1 && pwd -P)"

if [[ -z "${DOTFILES_USER_RC_LOADED:-}" ]] && [[ -f "${HOME}/.dotfilesrc" ]]; then
    DOTFILES_USER_RC_LOADED=1
    . "${HOME}/.dotfilesrc"
fi

if [[ "${DOTFILES_AUTO_SWITCH_ZSH:-0}" = "1" ]] \
    && [[ $- == *i* ]] \
    && [[ -z "${ZSH_VERSION:-}" ]] \
    && command -v zsh >/dev/null 2>&1; then
    exec zsh
fi

. "${DOTFILES_ROOT}/shared-core.sh"
. "${DOTFILES_ROOT}/shared-interactive.sh"
