# shellcheck shell=bash
# Shared shell configuration for bash and zsh.

if [[ -n "${DOTFILES_SHARED_SH_LOADED:-}" ]]; then
    return 0
fi
DOTFILES_SHARED_SH_LOADED=1

dotfiles_has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

dotfiles_append_path() {
    local path_entry="$1"

    [[ -n "${path_entry}" ]] || return 0
    case ":${PATH}:" in
        *":${path_entry}:"*) ;;
        *) PATH="${PATH}:${path_entry}" ;;
    esac
}

if [[ -f "${HOME}/.dotfilesrc" ]]; then
    . "${HOME}/.dotfilesrc"
fi

export LANG="C.UTF-8"

if dotfiles_has_cmd locale; then
    for locale_name in en_US.UTF-8 C.UTF-8; do
        if locale -a | grep -qx "${locale_name}"; then
            export LANG="${locale_name}"
            break
        fi
    done
fi

export PATH="${HOME}/.venv/bin:${KREW_ROOT:-$HOME/.krew}/bin:${HOME}/go/bin:${HOME}/.local/bin:${HOME}/.cache/cloud-code/installer/google-cloud-sdk/bin:/usr/local/bin:${PATH}"
export EDITOR='vim'
export RICH_TERMINALS='iTerm.app Terminal-Plus Babun gnome gnome-wayland powerline-compat gnome-terminal chrome code deepin-terminal'

if [[ -f /etc/profile.d/vte.sh ]]; then
    if [[ -n "${TILIX_ID:-}" ]] || [[ -n "${VTE_VERSION:-}" ]]; then
        . /etc/profile.d/vte.sh
    fi
fi

if dotfiles_has_cmd vim; then
    export EDITOR='vim'
elif dotfiles_has_cmd nano; then
    export EDITOR='nano'
elif dotfiles_has_cmd pico; then
    export EDITOR='pico'
else
    echo "Warning: Could not find an editor. Have fun." 1>&2
fi

NPM_PACKAGES="${HOME}/.npm-packages"
if [[ ! -e "${NPM_PACKAGES}" ]]; then
    mkdir -p "${NPM_PACKAGES}"
fi

export PATH="${NPM_PACKAGES}/bin:${PATH}"

if dotfiles_has_cmd manpath; then
    unset MANPATH
    manpath_value="$(manpath)"
    export MANPATH="${NPM_PACKAGES}/share/man:${manpath_value}"
fi

if [[ -n "${SALT_GIT_ROOT_LOCATIONS:-}" ]]; then
    for root in ${SALT_GIT_ROOT_LOCATIONS}; do
        if [[ -f "${root}/bootstrap/bashrc.sh" ]]; then
            . "${root}/bootstrap/bashrc.sh"
        fi
    done
fi

if [[ -d "${HOME}/Applications/Android/SDK" ]]; then
    export ANDROID_HOME="${HOME}/Applications/Android/SDK"
    dotfiles_append_path "${ANDROID_HOME}/emulator"
    dotfiles_append_path "${ANDROID_HOME}/tools"
    dotfiles_append_path "${ANDROID_HOME}/tools/bin"
    dotfiles_append_path "${ANDROID_HOME}/platform-tools"
fi

if [[ -d "${HOME}/.python3-venv/bin" ]]; then
    dotfiles_append_path "${HOME}/.python3-venv/bin"
fi

if [[ -d "${HOME}/.local/state/vs-kubernetes-tools" ]]; then
    for tool_dir in "${HOME}"/.local/state/vs-kubernetes-tools/*; do
        [[ -e "${tool_dir}" ]] || continue

        if [[ -e "${tool_dir}/$(basename "${tool_dir}")" ]]; then
            dotfiles_append_path "${tool_dir}"
            continue
        fi

        if [[ -d "${tool_dir}" ]]; then
            nested_dir=$(find "${tool_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)
            if [[ -n "${nested_dir}" ]] && [[ -e "${nested_dir}/$(basename "${tool_dir}")" ]]; then
                dotfiles_append_path "${nested_dir}"
            else
                echo "Warning: Found Cloud Code tool ${tool_dir} but could not find binary." 1>&2
            fi
        fi
    done
fi

if [[ -d "${HOME}/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin" ]]; then
    dotfiles_append_path "${HOME}/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin"
fi

if [[ -d "${HOME}/Documents/Code/salt" ]]; then
    . "${HOME}/Documents/Code/salt/bootstrap/bashrc.sh"
fi

if [[ -f "${HOME}/.tmuxinator/aliases" ]]; then
    . "${HOME}/.tmuxinator/aliases"
fi

if dotfiles_has_cmd clockify-cli; then
    alias clock='clockify-cli'
fi

if [[ -n "${KUBERNETES_DIAGNOSTIC_IMAGE:-}" ]] && [[ -n "${KUBERNETES_DIAGNOSTIC_SECRET:-}" ]]; then
    if [[ -z "${KUBERNETES_DIAGNOSTIC_NAMESPACE:-}" ]]; then
        echo "Warning: KUBERNETES_DIAGNOSTIC_IMAGE is set but either KUBERNETES_DIAGNOSTIC_SECRET or KUBERNETES_DIAGNOSTIC_NAMESPACE are not." 1>&2
    else
        kwtf() {
            kubectl run -n "${KUBERNETES_DIAGNOSTIC_NAMESPACE}" diag --restart=Never --image="${KUBERNETES_DIAGNOSTIC_IMAGE}" --command -t --overrides='{"spec":{"imagePullSecrets":[{"name":"'"${KUBERNETES_DIAGNOSTIC_SECRET}"'"}]}}' -i --attach --rm
        }
    fi
fi

alias git-fuck='git add . && git commit --amend --no-edit -a && git push --force'
alias kubeseal='kubeseal-interactive'

if dotfiles_has_cmd secret-tool; then
    mkdir -p "${HOME}/.copilot"
    secret-tool lookup service copilot-cli account "https://github.com:ikogan" > "${HOME}/.copilot/github-token" && \
        chmod 600 "${HOME}/.copilot/github-token"
fi

if dotfiles_has_cmd highlight; then
    pretty() {
        highlight -l -O xterm256 --style=molokai --syntax="$1"
    }
fi

case "${DOTFILES_SHELL:-}" in
    bash)
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

        if dotfiles_has_cmd kubecolor; then
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
        ;;
    zsh)
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

        if dotfiles_has_cmd kubecolor; then
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
        ;;
esac

export NVM_DIR="${HOME}/.nvm"
[ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh"
[ -s "${NVM_DIR}/bash_completion" ] && . "${NVM_DIR}/bash_completion"
