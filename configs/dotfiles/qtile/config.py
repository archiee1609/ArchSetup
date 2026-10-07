# ==============================================================================
# Qtile Configuration for Intel UHD 620 + AMD Radeon R5 M330 Laptop
# ==============================================================================

import os
import subprocess
from libqtile import bar, layout, widget, hook
from libqtile.config import Click, Drag, Group, Key, Match, Screen
from libqtile.lazy import lazy

mod = "mod4"
terminal = "kitty"

keys = [
    # Window Focus Navigation
    Key([mod], "h", lazy.layout.left(), desc="Move focus to left"),
    Key([mod], "l", lazy.layout.right(), desc="Move focus to right"),
    Key([mod], "j", lazy.layout.down(), desc="Move focus down"),
    Key([mod], "k", lazy.layout.up(), desc="Move focus up"),
    Key([mod], "space", lazy.layout.next(), desc="Move window focus to other window"),

    # Window Movement
    Key([mod, "shift"], "h", lazy.layout.shuffle_left(), desc="Move window to the left"),
    Key([mod, "shift"], "l", lazy.layout.shuffle_right(), desc="Move window to the right"),
    Key([mod, "shift"], "j", lazy.layout.shuffle_down(), desc="Move window down"),
    Key([mod, "shift"], "k", lazy.layout.shuffle_up(), desc="Move window up"),

    # Window Resizing
    Key([mod, "control"], "h", lazy.layout.grow_left(), desc="Grow window to the left"),
    Key([mod, "control"], "l", lazy.layout.grow_right(), desc="Grow window to the right"),
    Key([mod, "control"], "j", lazy.layout.grow_down(), desc="Grow window down"),
    Key([mod, "control"], "k", lazy.layout.grow_up(), desc="Grow window up"),
    Key([mod], "n", lazy.layout.normalize(), desc="Reset all window sizes"),

    # Applications & Launchers
    Key([mod], "Return", lazy.spawn(terminal), desc="Launch terminal"),
    Key([mod], "d", lazy.spawn("rofi -show drun"), desc="Launch application launcher"),
    Key([mod], "r", lazy.spawn("rofi -show run"), desc="Run command launcher"),

    # Window Management
    Key([mod], "q", lazy.window.kill(), desc="Kill focused window"),
    Key([mod], "f", lazy.window.toggle_fullscreen(), desc="Toggle fullscreen"),
    Key([mod], "t", lazy.window.toggle_floating(), desc="Toggle floating"),
    Key([mod], "Tab", lazy.next_layout(), desc="Toggle between layouts"),

    # Qtile Controls
    Key([mod, "control"], "r", lazy.reload_config(), desc="Reload config"),
    Key([mod, "control"], "q", lazy.shutdown(), desc="Shutdown Qtile"),

    # Hardware Audio Controls (WirePlumber / PipeWire)
    Key([], "XF86AudioRaiseVolume", lazy.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")),
    Key([], "XF86AudioLowerVolume", lazy.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")),
    Key([], "XF86AudioMute", lazy.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")),

    # Hardware Brightness Controls (brightnessctl)
    Key([], "XF86MonBrightnessUp", lazy.spawn("brightnessctl set +5%")),
    Key([], "XF86MonBrightnessDown", lazy.spawn("brightnessctl set 5%-")),
]

# Workspaces / Groups
groups = [Group(i) for i in "123456"]

for i in groups:
    keys.extend([
        Key([mod], i.name, lazy.group[i.name].toscreen(), desc=f"Switch to group {i.name}"),
        Key([mod, "shift"], i.name, lazy.window.togroup(i.name, switch_group=False),
            desc=f"Move focused window to group {i.name}"),
    ])

# Layout styling
colors = {
    "bg": "#1e1e2e",
    "fg": "#cdd6f4",
    "accent": "#89b4fa",
    "inactive": "#45475a",
    "active": "#f5e0dc",
    "bar_bg": "#11111b"
}

layout_theme = {
    "border_width": 2,
    "margin": 6,
    "border_focus": colors["accent"],
    "border_normal": colors["inactive"]
}

layouts = [
    layout.Columns(**layout_theme, border_on_single=True),
    layout.Max(),
    layout.Floating(**layout_theme)
]

widget_defaults = dict(
    font="JetBrainsMono Nerd Font",
    fontsize=11,
    padding=4,
    foreground=colors["fg"]
)
extension_defaults = widget_defaults.copy()

screens = [
    Screen(
        top=bar.Bar(
            [
                widget.GroupBox(
                    active=colors["fg"],
                    inactive=colors["inactive"],
                    highlight_method="line",
                    highlight_color=[colors["bar_bg"], colors["bg"]],
                    this_current_screen_border=colors["accent"],
                    urgent_border="#f38ba8",
                    padding_y=3,
                    padding_x=6,
                ),
                widget.Sep(linewidth=1, padding=10, foreground=colors["inactive"]),
                widget.CurrentLayout(foreground=colors["accent"]),
                widget.WindowName(max_chars=40, foreground=colors["fg"]),
                
                widget.Spacer(),
                
                # System Status Widgets
                widget.TextBox(text="󰻠", foreground="#a6e3a1"),
                widget.CPU(format="{load_percent}%", update_interval=2),
                
                widget.TextBox(text="󰍛", foreground="#f9e2af"),
                widget.Memory(format="{MemPercent}%", update_interval=2),
                
                widget.TextBox(text="󰁹", foreground="#f5c2e7"),
                widget.Battery(
                    format="{percent:2.0%}",
                    update_interval=10,
                    unknown_char="?",
                    charge_char="▲",
                    discharge_char="▼"
                ),
                
                widget.TextBox(text="󰕾", foreground=colors["accent"]),
                widget.Volume(fmt="{}", update_interval=0.2),
                
                widget.Sep(linewidth=1, padding=10, foreground=colors["inactive"]),
                widget.Clock(format="%Y-%m-%d %H:%M", foreground=colors["fg"]),
                widget.Systray(padding=5),
            ],
            28,
            background=colors["bar_bg"],
            margin=[4, 6, 0, 6],
            opacity=0.95
        ),
    ),
]

# Drag and Click Floating Rules
mouse = [
    Drag([mod], "Button1", lazy.window.set_position_floating(), start=lazy.window.get_position()),
    Drag([mod], "Button3", lazy.window.set_size_floating(), start=lazy.window.get_size()),
    Click([mod], "Button2", lazy.window.bring_to_front()),
]

dgroups_key_binder = None
dgroups_app_rules = []
follow_mouse_focus = True
bring_front_click = False
floats_kept_above = True
cursor_warp = False

floating_layout = layout.Floating(
    float_rules=[
        *layout.Floating.default_float_rules,
        Match(wm_class="confirmreset"),
        Match(wm_class="makebranch"),
        Match(wm_class="maketag"),
        Match(wm_class="ssh-askpass"),
        Match(title="branchdialog"),
        Match(title="pinentry"),
        Match(wm_class="pavucontrol"),
    ],
    border_focus=colors["accent"],
    border_normal=colors["inactive"],
    border_width=2
)
auto_fullscreen = True
focus_on_window_activation = "smart"
reconfigure_screens = True
auto_minimize = True
wmname = "LG3D"

# Autostart applications
@hook.subscribe.startup_once
def autostart():
    home = os.path.expanduser("~")
    # Launch picom compositor
    subprocess.Popen(["picom", "-b"])
    # Set background color or feh if available
    subprocess.Popen(["xsetroot", "-solid", "#1e1e2e"])
