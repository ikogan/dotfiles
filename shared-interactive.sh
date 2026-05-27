# shellcheck shell=bash
# Shared shell configuration for bash and zsh - interactive setup.
# This should be sourced after oh-my-zsh (for zsh) to ensure interactive features work properly.

if [[ -n "${DOTFILES_SHARED_INTERACTIVE_SH_LOADED:-}" ]]; then
    return 0
fi
DOTFILES_SHARED_INTERACTIVE_SH_LOADED=1

# Helper function (redefine here for safety)
dotfiles_has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
    # Zsh configuration
    if dotfiles_has_cmd kubectl; then
        mkdir -p "${HOME}/.zsh" >/dev/null 2>&1 || true
        unalias kubectl >/dev/null 2>&1 || true
        kubectl completion zsh > "${HOME}/.zsh/kubernetes.sh"
        source "${HOME}/.zsh/kubernetes.sh"
    fi

    if dotfiles_has_cmd clockify-cli; then
        # shellcheck disable=SC1090
        source <(clockify-cli completion zsh)
    fi

    if [[ -x "${HOME}/.local/bin/mcfly" ]]; then
        eval "$(${HOME}/.local/bin/mcfly init zsh)"
    fi

    if [[ -e "${HOME}/.zsh-aliases" ]]; then
        . "${HOME}/.zsh-aliases"
    fi

    if dotfiles_has_cmd kubectl && dotfiles_has_cmd kubecolor; then
        kubectl() {
            command kubecolor "$@"
        }
        if whence compdef >/dev/null 2>&1; then
            compdef kubecolor=kubectl
        fi
    fi

    if dotfiles_has_cmd pyenv; then
        export PYENV_ROOT="${HOME}/.pyenv"
        [[ -d ${PYENV_ROOT}/bin ]] && export PATH="${PYENV_ROOT}/bin:${PATH}"
        eval "$(pyenv init - zsh)"
    fi

    if dotfiles_has_cmd starship; then
        eval "$(starship init zsh)"
    fi

elif [[ -n "${BASH_VERSION:-}" ]]; then
    # Bash configuration
    if dotfiles_has_cmd kubectl; then
        # shellcheck disable=SC1090
        . <(kubectl completion bash)
    fi

    if dotfiles_has_cmd clockify-cli; then
        # shellcheck disable=SC1090
        . <(clockify-cli completion bash)
    fi

    if [[ -x "${HOME}/.local/bin/mcfly" ]]; then
        eval "$(${HOME}/.local/bin/mcfly init bash)"
    fi

    if dotfiles_has_cmd kubectl && dotfiles_has_cmd kubecolor; then
        kubectl() {
            command kubecolor "$@"
        }
        if declare -F __start_kubectl >/dev/null 2>&1; then
            complete -o default -F __start_kubectl kubectl kubecolor
        fi
    fi

    if dotfiles_has_cmd pyenv; then
        export PYENV_ROOT="${HOME}/.pyenv"
        [[ -d ${PYENV_ROOT}/bin ]] && export PATH="${PYENV_ROOT}/bin:${PATH}"
        eval "$(pyenv init - bash)"
    fi

    if [[ -e "${HOME}/.bash_aliases" ]]; then
        . "${HOME}/.bash_aliases"
    fi

    if dotfiles_has_cmd starship; then
        eval "$(starship init bash)"
    fi
fi
