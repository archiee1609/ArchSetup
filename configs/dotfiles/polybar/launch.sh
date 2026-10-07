#!/usr/bin/env bash
# Terminate already running bar instances
killall -q polybar

# Wait until the processes have been shut down
while pgrep -u $UID -x polybar >/dev/null; do sleep 0.2; done

# Launch Polybar
polybar main -c "$HOME/.config/polybar/config.ini" 2>&1 | tee -a /tmp/polybar.log & disown
