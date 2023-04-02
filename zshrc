if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

if [[ -f "${HOME}/.dotfilesrc" ]]; then
	source "${HOME}/.dotfilesrc"
fi

export LANG="C.UTF-8"

for LOCALE in en_US.UTF-8 C.UTF-8; do
    if [[ -n "$(locale -a | grep ${LOCALE})" ]]; then
        export LANG=${LOCALE}
        break
    fi
done

export ZSH_2000_DISABLE_RVM='true'
export ZSH="${HOME}/.oh-my-zsh"

ZSH_THEME="powerlevel10k/powerlevel10k"

HYPHEN_INSENSITIVE="true"
COMPLETION_WAITING_DOTS="true"

plugins=(k genpass gitfast kubetail colored-man-pages colorize docker helm ubuntu vagrant zsh-autosuggestions zsh-syntax-highlighting)

if which thefuck &>/dev/null; then
	plugins+=(thefuck)
fi

setopt histfcntllock

zstyle :omz:plugins:ssh-agent agent-forwarding on

source $ZSH/oh-my-zsh.sh

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

export EDITOR='vim'

if [[ -f /etc/profile.d/vte.sh ]]; then
	if [ $TILIX_ID ] || [ $VTE_VERSION ]; then
		source /etc/profile.d/vte.sh
	fi
fi

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$HOME/go/bin:$HOME/.bin:$HOME/.local/bin:$HOME/.cache/cloud-code/installer/google-cloud-sdk/bin:/usr/local/bin:${PATH}"

RICH_TERMINALS="iTerm.app Terminal-Plus Babun gnome gnome-wayland powerline-compat gnome-terminal chrome code deepin-terminal"

if [[ ! -z "$(which vim 2>/dev/null)" ]]; then
    export EDITOR=vim
elif [[ ! -z "$(which nano 2>/dev/null)" ]]; then
    export EDITOR=nano
elif [[ ! -z "$(which pico 2>/dev/null)" ]]; then
    export EDITOR=pico
else
    echo Warning: Could not find an editor. Have fun. 1>&2
fi

# Enable user global npm packages
NPM_PACKAGES="${HOME}/.npm-packages"
if [[ ! -e "${NPM_PACKAGES}" ]]; then
   mkdir "${NPM_PACKAGES}"
fi

export PATH="${NPM_PACKAGES}/bin:${PATH}"

if which manpath &>/dev/null; then
    unset MANPATH
    export MANPATH="${NPM_PACKAGES}/share/man:$(manpath)"
fi

if [[ -n "${SALT_GIT_ROOT_LOCATIONS}" ]]; then
	for ROOT in ${SALT_GIT_ROOT_LOCATIONS}; do
		if [[ -f "${ROOT}/bootstrap/bashrc.sh" ]]; then
			source "${ROOT}/bootstrap/bashrc.sh"
		fi
	done
fi

if [[ -d "$HOME/Applications/Android/SDK" ]]; then
	export ANDROID_HOME=$HOME/Applications/Android/SDK
	export PATH=$PATH:$ANDROID_HOME/emulator
	export PATH=$PATH:$ANDROID_HOME/tools
	export PATH=$PATH:$ANDROID_HOME/tools/bin
	export PATH=$PATH:$ANDROID_HOME/platform-tools
fi

alias git-fuck="git add . && git commit --amend --no-edit -a && git push --force"

if [[ -e "$HOME/.zsh/kubernetes.sh" ]]; then
	source "$HOME/.zsh/kubernetes.sh"
elif [[ -n "$(which kubectl 2>/dev/null)" ]]; then
	echo "Generating kubectl completions..."
	mkdir "$HOME/.zsh" || true
	kubectl completion zsh > "$HOME/.zsh/kubernetes.sh"
	source "$HOME/.zsh/kubernetes.sh"
fi

if [[ -f "{HOME}/.vs-kubernetes/tools/helm/linux-amd64/helm" ]]; then
    alias helm=${HOME}/.vs-kubernetes/tools/helm/linux-amd64/helm
fi

if [[ -f "${HOME}/.tmuxinator/aliases" ]]; then
    source "${HOME}/.tmuxinator/aliases"
fi

if which clockify-cli &>/dev/null; then
    source <(clockify-cli completion zsh)
    alias clock=$(clockify-cli)
fi

if [[ -f "${HOME}/.bin/mcfly" ]]; then
	eval "$("${HOME}"/.bin/mcfly init zsh)"
fi

if [[ -n "${KUBERNETES_DIAGNOSTIC_IMAGE}" ]] && [[ -n "${KUBERNETES_DIAGNOSTIC_SECRET}" ]]; then
	alias kwtf="kubectl run diag --restart=Never --image=${KUBERNETES_DIAGNOSTIC_IMAGE} --command -t --overrides='{\"spec\":{\"imagePullSecrets\":[{\"name\":\"${KUBERNETES_DIAGNOSTIC_SECRET}\"}]}}' -i --attach --rm"
fi

if [[ -e "${HOME}/.zsh-aliases" ]]; then
    . "${HOME}/.zsh-aliases"
fi

if which highlight &>/dev/null; then
    function pretty() {
        highlight -l -O xterm256 --style=molokai --syntax="$1"
    }
fi

if [[ -d "${HOME}/Documents/Code/salt" ]]; then
    source "${HOME}/Documents/Code/salt/bootstrap/bashrc.sh"
fi

[[ ! -f ~/.p10k.zsh ]] || source "${HOME}"/.p10k.zsh
