# shellcheck shell=bash
if [[ -f "${HOME}/.dotfilesrc" ]]; then
    source "${HOME}/.dotfilesrc"
fi

export LANG="C.UTF-8"

if command -v locale >/dev/null 2>&1; then
    for LOCALE in en_US.UTF-8 C.UTF-8; do
        if locale -a | grep -q "${LOCALE}"; then
            export LANG="${LOCALE}"
            break
        fi
    done
fi

export PATH="${HOME}/.venv/bin:${KREW_ROOT:-$HOME/.krew}/bin:$HOME/go/bin:$HOME/.local/bin:$HOME/.cache/cloud-code/installer/google-cloud-sdk/bin:/usr/local/bin:${PATH}"
export EDITOR='vim'

if command -v vim >/dev/null 2>&1; then
    export EDITOR=vim
elif command -v nano >/dev/null 2>&1; then
    export EDITOR=nano
elif command -v pico >/dev/null 2>&1; then
    export EDITOR=pico
else
    echo "Warning: Could not find an editor. Have fun." 1>&2
fi

# Enable user global npm packages.
NPM_PACKAGES="${HOME}/.npm-packages"
if [[ ! -e "${NPM_PACKAGES}" ]]; then
    mkdir -p "${NPM_PACKAGES}"
fi

export PATH="${NPM_PACKAGES}/bin:${PATH}"

if command -v manpath >/dev/null 2>&1; then
    unset MANPATH
    manpath_value=$(manpath)
    export MANPATH="${NPM_PACKAGES}/share/man:${manpath_value}"
fi

if [[ -n "${SALT_GIT_ROOT_LOCATIONS}" ]]; then
    for ROOT in ${SALT_GIT_ROOT_LOCATIONS}; do
        if [[ -f "${ROOT}/bootstrap/bashrc.sh" ]]; then
            source "${ROOT}/bootstrap/bashrc.sh"
        fi
    done
fi

if [[ -d "$HOME/Applications/Android/SDK" ]]; then
    export ANDROID_HOME="$HOME/Applications/Android/SDK"
    export PATH="$PATH:$ANDROID_HOME/emulator"
    export PATH="$PATH:$ANDROID_HOME/tools"
    export PATH="$PATH:$ANDROID_HOME/tools/bin"
    export PATH="$PATH:$ANDROID_HOME/platform-tools"
fi

if [[ -d "${HOME}/.python3-venv/bin" ]]; then
    export PATH="${PATH}:${HOME}/.python3-venv/bin"
fi

if [[ -d "${HOME}/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin" ]]; then
    export PATH="$PATH:${HOME}/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin"
fi

if [[ -d "${HOME}/Documents/Code/salt" ]]; then
    source "${HOME}/Documents/Code/salt/bootstrap/bashrc.sh"
fi

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

if command -v kubectl >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source <(kubectl completion bash)
fi

if command -v clockify-cli >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source <(clockify-cli completion bash)
    alias clock='clockify-cli'
fi

if [[ -x "${HOME}/.local/bin/mcfly" ]]; then
    eval "$(${HOME}/.local/bin/mcfly init bash)"
fi

if [[ -n "${KUBERNETES_DIAGNOSTIC_IMAGE}" ]] && [[ -n "${KUBERNETES_DIAGNOSTIC_SECRET}" ]]; then
    if [[ -z "${KUBERNETES_DIAGNOSTIC_SECRET}" ]] || [[ -z "${KUBERNETES_DIAGNOSTIC_NAMESPACE}" ]]; then
        echo "Warning: KUBERNETES_DIAGNOSTIC_IMAGE is set but either KUBERNETES_DIAGNOSTIC_SECRET or KUBERNETES_DIAGNOSTIC_NAMESPACE are not." 1>&2
    else
        kwtf() {
            kubectl run -n "${KUBERNETES_DIAGNOSTIC_NAMESPACE}" diag --restart=Never --image="${KUBERNETES_DIAGNOSTIC_IMAGE}" --command -t --overrides="{\"spec\":{\"imagePullSecrets\":[{\"name\":\"${KUBERNETES_DIAGNOSTIC_SECRET}\"}]}}" -i --attach --rm
        }
    fi
fi

alias git-fuck='git add . && git commit --amend --no-edit -a && git push --force'
alias kubeseal='kubeseal-interactive'

if command -v kubecolor >/dev/null 2>&1; then
    alias kubectl='kubecolor'
fi

if command -v pyenv >/dev/null 2>&1; then
    export PYENV_ROOT="$HOME/.pyenv"
    [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init - bash)"
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

if [[ -e "${HOME}/.bash_aliases" ]]; then
    source "${HOME}/.bash_aliases"
fi

if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi
