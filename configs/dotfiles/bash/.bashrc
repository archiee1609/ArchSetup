# ~/.bashrc
# Interactive Bash Configuration for Arch Linux BSPWM Workstation

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Shell history settings
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend
shopt -s checkwinsize

# Export user environment paths
export PATH="$HOME/.local/bin:$HOME/.config/bspwm/bin:/usr/local/bin:$PATH"

# Editor environment
export EDITOR="neovim"
export VISUAL="neovim"

# Terminal prompt styling with git branch integration
CLR_USER="\[\033[01;32m\]"
CLR_HOST="\[\033[01;34m\]"
CLR_DIR="\[\033[01;36m\]"
CLR_GIT="\[\033[01;33m\]"
CLR_RESET="\[\033[00m\]"

git_prompt() {
    local branch
    branch=$(git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/')
    if [[ -n "$branch" ]]; then
        printf "%s%s%s" "${CLR_GIT}" "$branch" "${CLR_RESET}"
    fi
}

PS1="${CLR_USER}\u${CLR_RESET}@${CLR_HOST}\h${CLR_RESET}:${CLR_DIR}\w${CLR_RESET}\$(git_prompt)\$ "

# Quality-of-life aliases
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'
alias df='df -h'
alias free='free -m'

# Package management helpers
alias pac-update='sudo pacman -Syu'
alias pac-clean='sudo pacman -Rns $(pacman -Qtdq) 2>/dev/null || true'

# Rice and WM quick commands
alias bspwm-reload='bspc wm -r'
alias sxhkd-reload='pkill -USR1 -x sxhkd'
alias theme-menu='~/.config/bspwm/rofi/bin/themes'

# Source system bash-completion if available
if [[ -f /usr/share/bash-completion/bash_completion ]]; then
    source /usr/share/bash-completion/bash_completion
fi
