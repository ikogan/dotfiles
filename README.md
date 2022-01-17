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
export KUBERNETES_DIAGNOSTIC_IMAGE=
export KUBERNETES_DIAGNOSTIC_SECRET=
```
