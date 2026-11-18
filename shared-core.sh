# shellcheck shell=bash
# Shared shell configuration for bash and zsh - core setup.
# This should be sourced early, before shell-specific initialization. It is
# safe to source again (for example `source ~/.zshrc`) to pick up changes.

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

# Put a directory first in PATH, removing any other occurrence, so sourcing
# this file again doesn't add duplicates but the directory still takes
# precedence over the same one later in an inherited PATH.
dotfiles_prepend_path() {
    local path_entry="$1" rest

    [[ -n "${path_entry}" ]] || return 0
    rest=":${PATH}:"
    while [[ "${rest}" == *":${path_entry}:"* ]]; do
        rest="${rest//:"${path_entry}":/:}"
    done
    rest="${rest#:}"
    rest="${rest%:}"
    PATH="${path_entry}${rest:+:${rest}}"
}

# Drop repeated PATH entries, keeping the first, for tools such as nvm that add
# to PATH every time they're loaded.
dotfiles_dedupe_path() {
    local rest="${PATH}:" path_entry result=""

    while [[ -n "${rest}" ]]; do
        path_entry="${rest%%:*}"
        rest="${rest#*:}"
        [[ -n "${path_entry}" ]] || continue
        case ":${result}:" in
            *":${path_entry}:"*) ;;
            *) result="${result:+${result}:}${path_entry}" ;;
        esac
    done
    PATH="${result}"
}

if [[ -z "${DOTFILES_USER_RC_LOADED:-}" ]] && [[ -f "${HOME}/.dotfilesrc" ]]; then
    DOTFILES_USER_RC_LOADED=1
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

# Prepended in reverse, so ~/.venv/bin ends up first.
for path_entry in \
    /usr/local/bin \
    "${HOME}/.cache/cloud-code/installer/google-cloud-sdk/bin" \
    "${HOME}/.local/bin" \
    "${HOME}/go/bin" \
    "${KREW_ROOT:-$HOME/.krew}/bin" \
    "${HOME}/.venv/bin"; do
    dotfiles_prepend_path "${path_entry}"
done
unset path_entry
export PATH
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

dotfiles_prepend_path "${NPM_PACKAGES}/bin"

NVM_INIT="/usr/share/nvm/init-nvm.sh"

if [[ -f "${NVM_INIT}" ]]; then
    source "${NVM_INIT}"
fi

if [[ -d "${HOME}/.cargo/bin" ]]; then
    dotfiles_prepend_path "${HOME}/.cargo/bin"
fi

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

if [[ -f /run/user/$(id -u)/podman/podman.sock ]]; then
  export DOCKER_HOST=unix://run/user/$(id -u)/podman/podman.sock
fi

alias git-fuck='git add . && git commit --amend --no-edit -a && git push --force'
alias kubeseal='kubeseal-interactive'

# Gitea's clone button still shows `tea clone <owner>/<repo>`, but the tea CLI
# has been replaced by gt, which clones with `gt repo clone`. Other tea
# commands don't map one-to-one onto gt's, so only clone is translated.
if dotfiles_has_cmd gt && ! dotfiles_has_cmd tea; then
    tea() {
        if [[ "${1:-}" == "clone" ]]; then
            shift
            gt repo clone "$@"
        else
            echo "tea has been replaced by gt; only 'tea clone' is translated. See: gt --help" >&2
            return 1
        fi
    }
fi

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

