# ~/.bash_profile
# Login Profile for Arch Linux

[[ -f ~/.bashrc ]] && . ~/.bashrc

# Ensure user PATH is exported
export PATH="$HOME/.local/bin:$HOME/.config/bspwm/bin:/usr/local/bin:$PATH"
