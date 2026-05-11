# Personal Dotfiles

```bash
./install.sh
```

Not using a dotfiles manager tool yet, this will setup:

- zsh + oh-my-zsh
- vim
- kubectl krew plugins

**Note**: The install will overwrite existing configurations without prompting.

Don't forget to setup `~/.dotfilesrc` with anything that might
change between hosts, like:

```bash
KUBERNETES_DIAGNOSTIC_IMAGE=
KUBERNETES_DIAGNOSTIC_SECRET=
SALT_GIT_ROOT_LOCATIONS=("${HOME}/Documents/Code/salt" "${HOME}/Documents/Code/some-other-place")
DOTFILES_AUTO_SWITCH_ZSH=1
```

`DOTFILES_AUTO_SWITCH_ZSH=1` makes interactive bash sessions immediately `exec zsh` when zsh is available.

`install.sh` uses `${HOME}/.tmp` for temp working directories, so it does not rely on `/tmp` being executable.
