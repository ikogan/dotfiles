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
. "${DOTFILES_ROOT}/shared.sh"

# Bash-it (oh-my-zsh-like framework for bash).
export BASH_IT="${HOME}/.bash_it"
if [[ -f "${BASH_IT}/bash_it.sh" ]]; then
    export BASH_IT_THEME='none'
    export BASH_IT_SHOW_CLOCK=false
    export BASH_IT_USE_FZF=false

    # Keep this close to the zsh setup while avoiding hard failures if plugins are missing.
    # shellcheck disable=SC2034
    plugins=(git kubectl docker)
    # shellcheck disable=SC2034
    aliases=(general git docker kubectl tmux vim)
    # shellcheck disable=SC2034
    completions=(git kubectl docker pip ssh tmux)

    source "${BASH_IT}/bash_it.sh"
fi
