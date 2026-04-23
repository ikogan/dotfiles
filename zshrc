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

export DOTFILES_SHELL='zsh'
DOTFILES_ZSHRC_PATH="$(dotfiles_resolve_path "${(%):-%N}")"
DOTFILES_ROOT="$(cd -- "$(dirname -- "${DOTFILES_ZSHRC_PATH}")" >/dev/null 2>&1 && pwd -P)"
source "${DOTFILES_ROOT}/shared.sh"

export ZSH_2000_DISABLE_RVM='true'
export ZSH="${HOME}/.oh-my-zsh"

ZSH_THEME=""

HYPHEN_INSENSITIVE="true"
COMPLETION_WAITING_DOTS="true"

plugins=(k genpass gitfast kubetail colored-man-pages colorize docker helm ubuntu vagrant zsh-autosuggestions zsh-syntax-highlighting zsh-github-copilot)

if which thefuck &>/dev/null; then
	plugins+=(thefuck)
fi

setopt histfcntllock

zstyle :omz:plugins:ssh-agent agent-forwarding on

if [[ -f "${ZSH}/oh-my-zsh.sh" ]]; then
	source "${ZSH}/oh-my-zsh.sh"
else
	echo "Warning: Oh My Zsh is not installed. Continuing with base zsh configuration." 1>&2
fi

typeset -gA ZSH_HIGHLIGHT_STYLES

ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)
ZSH_HIGHLIGHT_STYLES[cursor]='bold'

ZSH_HIGHLIGHT_STYLES[alias]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[suffix-alias]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[function]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[command]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[hashed-command]='fg=green,bold'

ZSH_COLORIZE_STYLE="monokai"

rule () {
	print -Pn '%F{blue}'
	local columns=$(tput cols)
	for ((i=1; i<=columns; i++)); do
	   printf "\u2588"
	done
	print -P '%f'
}

function _my_clear() {
	echo
	rule
	zle clear-screen
}
zle -N _my_clear

bindkey '^l' _my_clear
#bindkey '\C-i' zsh_gh_copilot_suggest
# TODO: Figure out how to bind explain ,the below doesn't wokr.
# bindkey '\C-S-i' zsh_gh_copilot_explain
