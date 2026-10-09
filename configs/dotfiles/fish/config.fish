# ~/.config/fish/config.fish
# Modern Fish Shell Configuration for Arch Linux BSPWM Workstation

# Disable default startup greeting
set -g fish_greeting ""

# Environment PATH exports
fish_add_path -g $HOME/.local/bin $HOME/.config/bspwm/bin /usr/local/bin

# Text editor preferences
set -gx EDITOR neovim
set -gx VISUAL neovim

# Syntax highlighting & prompt color palette
set -g fish_color_normal normal
set -g fish_color_command 89b4fa
set -g fish_color_quote a6e3a1
set -g fish_color_redirection f5c2e7
set -g fish_color_end f9e2af
set -g fish_color_error f38ba8
set -g fish_color_param cdd6f4
set -g fish_color_comment 6c7086
set -g fish_color_selection --background=45475a
set -g fish_color_search_match --background=313244
set -g fish_color_operator 94e2d5
set -g fish_color_escape f5e0dc
set -g fish_color_autosuggestion 585b70

# Quality-of-life aliases
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'
alias df='df -h'
alias free='free -m'

# Package management helpers
alias pac-update='sudo pacman -Syu'
alias pac-clean='sudo pacman -Rns (pacman -Qtdq 2>/dev/null) 2>/dev/null; or true'

# Rice and WM quick commands
alias bspwm-reload='bspc wm -r'
alias sxhkd-reload='pkill -USR1 -x sxhkd'
alias theme-menu='~/.config/bspwm/rofi/bin/themes'

# Clean interactive prompt with Git integration
function fish_prompt
    set -l last_status $status
    set_color 89b4fa
    echo -n (whoami)@(prompt_hostname)
    set_color normal
    echo -n ':'
    set_color a6e3a1
    echo -n (prompt_pwd)
    set_color f9e2af
    echo -n (fish_git_prompt)
    if test $last_status -ne 0
        set_color f38ba8
        echo -n " [$last_status]"
    end
    set_color normal
    echo -n ' > '
end
