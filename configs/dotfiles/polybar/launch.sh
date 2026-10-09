#!/usr/bin/env bash
# Terminate already running bar instances
killall -q polybar

# Wait until the processes have been shut down
while pgrep -u $UID -x polybar >/dev/null; do sleep 0.2; done

# Resolve Polybar configuration file
POLY_CFG="$HOME/.config/bspwm/polybar/config"
if [[ ! -f "$POLY_CFG" ]]; then
    POLY_CFG="$HOME/.config/polybar/config.ini"
fi

# Launch Polybar
polybar main -c "$POLY_CFG" 2>&1 | tee -a /tmp/polybar.log & disown
