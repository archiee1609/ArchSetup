#!/usr/bin/env bash
# ==============================================================================
# Stage 2: Post-Chroot System Configuration & Environment Provisioning
# Hardware-Aware & Adaptive (Intel/AMD/NVIDIA/VMs, Laptops, Desktops)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library and user configuration
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/lib/common.sh"
else
    echo "[INFO] Running within chroot environment."
    CLR_RESET="\033[0m"; CLR_INFO="\033[1;34m"; CLR_WARN="\033[1;33m"
    CLR_ERROR="\033[1;31m"; CLR_SUCCESS="\033[1;32m"; CLR_STEP="\033[1;36m"
    CLR_BOLD="\033[1m"
    log_info() { printf "${CLR_INFO}[INFO]${CLR_RESET} %s\n" "$*"; }
    log_warn() { printf "${CLR_WARN}[WARN]${CLR_RESET} %s\n" "$*"; }
    log_error() { printf "${CLR_ERROR}[ERROR]${CLR_RESET} %s\n" "$*" >&2; }
    log_success() { printf "${CLR_SUCCESS}[SUCCESS]${CLR_RESET} %s\n" "$*"; }
    log_step() { printf "\n${CLR_STEP}==>${CLR_RESET} ${CLR_BOLD}%s${CLR_RESET}\n" "$*"; }
fi

if [[ -f "${SCRIPT_DIR}/lib/detect.sh" ]]; then
    # shellcheck source=lib/detect.sh
    source "${SCRIPT_DIR}/lib/detect.sh"
fi

if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck source=config.env
    source "${SCRIPT_DIR}/config.env"
fi

# Load pre-detected hardware profile if available, or probe directly
if [[ -f "${SCRIPT_DIR}/hardware.env" ]]; then
    # shellcheck source=hardware.env
    source "${SCRIPT_DIR}/hardware.env"
elif [[ "${AUTO_DETECT_HARDWARE:-true}" == "true" ]]; then
    detect_hardware
    apply_hardware_profile
fi

CONFIGS_DIR="${SCRIPT_DIR}/configs"

# ------------------------------------------------------------------------------
# 1. System Localization, Clock & Hostname
# ------------------------------------------------------------------------------
log_step "Configuring Timezone, Clock & Localization"

log_info "Setting timezone to ${TIMEZONE}..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

log_info "Configuring locale (${LOCALE})..."
sed -i "s/^#\(${LOCALE}\)/\1/" /etc/locale.gen
if ! grep -q "^${LOCALE}" /etc/locale.gen; then
    echo "${LOCALE} UTF-8" >> /etc/locale.gen
fi
locale-gen

echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

log_info "Setting hostname (${HOSTNAME})..."
echo "${HOSTNAME}" > /etc/hostname

cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# ------------------------------------------------------------------------------
# 2. Pacman Optimization, Multilib, Chaotic-AUR & AUR Helper (Paru)
# ------------------------------------------------------------------------------
log_step "Configuring Pacman, Repositories & AUR Helper"

# Enable ParallelDownloads and Color
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

# 1. Enable Multilib Repository
if [[ "${ENABLE_MULTILIB:-true}" == "true" ]]; then
    log_info "Activating multilib repository..."
    if grep -q "\[multilib\]" /etc/pacman.conf; then
        sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
    else
        cat <<EOF >> /etc/pacman.conf

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    fi
    log_success "Multilib repository activated."
fi

# 2. Enable Chaotic-AUR Repository
if [[ "${ENABLE_CHAOTIC_AUR:-true}" == "true" ]]; then
    log_info "Activating Chaotic-AUR repository..."
    # Retrieve and sign Chaotic-AUR primary signing key
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com 2>/dev/null || \
    pacman-key --recv-key 3056513887B78AEB --keyserver hkps://keyserver.ubuntu.com 2>/dev/null || true
    pacman-key --lsign-key 3056513887B78AEB 2>/dev/null || true

    # Install chaotic-keyring and chaotic-mirrorlist
    log_info "Installing Chaotic-AUR keyring and mirrorlist..."
    pacman -U --noconfirm --needed 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 2>/dev/null || true
    pacman -U --noconfirm --needed 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' 2>/dev/null || true

    # Append [chaotic-aur] configuration if missing
    if ! grep -q "^\[chaotic-aur\]" /etc/pacman.conf; then
        cat <<EOF >> /etc/pacman.conf

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
    fi
    log_success "Chaotic-AUR repository configured in /etc/pacman.conf."
fi

# Refresh pacman package databases
log_info "Synchronizing package databases..."
pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
pacman -Sy --noconfirm 2>/dev/null || true

# 3. Install Paru AUR Helper from Chaotic-AUR
if [[ "${INSTALL_PARU:-true}" == "true" ]]; then
    log_info "Installing paru AUR helper..."
    if pacman -S --noconfirm --needed paru 2>/dev/null || pacman -S --noconfirm --needed paru-bin 2>/dev/null; then
        log_success "paru installed successfully via repository."
    else
        log_info "Repository package not directly reachable; will build paru-bin via AUR fallback after user creation."
    fi
fi

# ------------------------------------------------------------------------------
# 3. Graphics, PRIME Offload & Display Packages
# ------------------------------------------------------------------------------
log_step "Installing Graphics Drivers & PRIME Offload Utilities"

# Fallback graphics packages if not pre-populated
if [[ ${#GRAPHICS_PACKAGES[@]} -eq 0 ]]; then
    GRAPHICS_PACKAGES=(
        mesa
        mesa-utils
        lib32-mesa
    )
fi

# Filter out 32-bit multilib packages if multilib repository is disabled
if [[ "${ENABLE_MULTILIB:-true}" != "true" ]]; then
    _filtered_gfx=()
    for _pkg in "${GRAPHICS_PACKAGES[@]}"; do
        if [[ "$_pkg" != lib32-* ]]; then
            _filtered_gfx+=("$_pkg")
        fi
    done
    GRAPHICS_PACKAGES=("${_filtered_gfx[@]}")
fi

log_info "Installing tailored graphics drivers: ${GRAPHICS_PACKAGES[*]}"
pacman -S --noconfirm --needed "${GRAPHICS_PACKAGES[@]}"

# Deploy PRIME Run Script tailored to GPU architecture
log_info "Configuring prime-run wrapper (/usr/local/bin/prime-run)..."
mkdir -p /usr/local/bin
if [[ "${PRIME_TYPE:-none}" == "nvidia" ]]; then
    cat <<'EOF' > /usr/local/bin/prime-run
#!/usr/bin/env bash
# PRIME Render Offload to NVIDIA discrete GPU
set -euo pipefail
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "$@"
EOF
elif [[ "${PRIME_TYPE:-none}" == "amd" ]]; then
    cat <<'EOF' > /usr/local/bin/prime-run
#!/usr/bin/env bash
# PRIME Render Offload to AMD Radeon dGPU (DRI_PRIME=1)
set -euo pipefail
export DRI_PRIME=1
exec "$@"
EOF
else
    cat <<'EOF' > /usr/local/bin/prime-run
#!/usr/bin/env bash
# Passthrough execution wrapper (single GPU or standard display)
exec "$@"
EOF
fi
chmod +x /usr/local/bin/prime-run
log_success "prime-run wrapper deployed (${PRIME_TYPE:-none})."

# ------------------------------------------------------------------------------
# 4. ZRAM Memory Configuration
# ------------------------------------------------------------------------------
log_step "Configuring ZRAM (zram-generator)"

mkdir -p /etc/systemd
cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram * ${ZRAM_FRACTION:-0.5}
compression-algorithm = ${ZRAM_ALGORITHM:-zstd}
swap-priority = 100
fs-type = swap
EOF
log_success "ZRAM generator configured (${ZRAM_FRACTION:-0.5} RAM, ${ZRAM_ALGORITHM:-zstd})."

# ------------------------------------------------------------------------------
# 5. Power & Thermal Management
# ------------------------------------------------------------------------------
log_step "Configuring Power & Thermal Management"

if [[ "${IS_VM:-0}" -eq 1 ]]; then
    log_info "Virtual Machine detected (${VIRT_TYPE:-generic}). Enabling hypervisor guest daemons..."
    case "${VIRT_TYPE:-none}" in
        oracle)
            systemctl enable vboxservice.service 2>/dev/null || true
            log_success "VirtualBox guest service enabled."
            ;;
        vmware)
            systemctl enable vmtoolsd.service vmware-vmblock-fuse.service 2>/dev/null || true
            log_success "VMware guest tools services enabled."
            ;;
        kvm|qemu)
            systemctl enable qemu-guest-agent.service 2>/dev/null || true
            log_success "QEMU guest agent service enabled."
            ;;
        *)
            log_info "Generic VM detected. No additional guest daemons required."
            ;;
    esac
else
    # Physical system: configure TLP and thermald
    POWER_PACKAGES=(
        tlp
        tlp-rdw
        powertop
    )

    if [[ "${CHASSIS_TYPE:-desktop}" == "laptop" ]]; then
        POWER_PACKAGES+=(brightnessctl)
    fi

    # thermald is an Intel-specific thermal daemon; skip on AMD CPUs
    if [[ "${DETECTED_CPU_VENDOR:-}" == "Intel" && "${CHASSIS_TYPE:-desktop}" == "laptop" ]]; then
        POWER_PACKAGES+=(thermald)
    fi

    pacman -S --noconfirm --needed "${POWER_PACKAGES[@]}"

    mkdir -p /etc/tlp.d
    if [[ -f "${CONFIGS_DIR}/power/tlp.conf" ]]; then
        cp "${CONFIGS_DIR}/power/tlp.conf" /etc/tlp.d/00-hardware-throttling.conf
        # Adapt governor if CPU is AMD
        if [[ "${DETECTED_CPU_VENDOR:-}" == "AMD" ]]; then
            sed -i 's/CPU_SCALING_GOVERNOR_ON_AC=powersave/CPU_SCALING_GOVERNOR_ON_AC=powersave/' /etc/tlp.d/00-hardware-throttling.conf
        fi
        # If Desktop, don't cap battery perf
        if [[ "${CHASSIS_TYPE:-desktop}" == "desktop" ]]; then
            sed -i 's/CPU_MAX_PERF_ON_BAT=70/CPU_MAX_PERF_ON_BAT=100/' /etc/tlp.d/00-hardware-throttling.conf
        fi
    fi

    systemctl enable tlp.service
    if [[ "${DETECTED_CPU_VENDOR:-}" == "Intel" && "${CHASSIS_TYPE:-desktop}" == "laptop" ]]; then
        systemctl enable thermald.service 2>/dev/null || true
        log_info "thermald service enabled for Intel thermal protection."
    fi
    log_success "Power management configured and enabled."
fi

# ------------------------------------------------------------------------------
# 6. Audio Stack (PipeWire)
# ------------------------------------------------------------------------------
log_step "Installing Audio Stack (PipeWire & WirePlumber)"

AUDIO_PACKAGES=(
    pipewire
    wireplumber
    pipewire-pulse
    pipewire-alsa
    pipewire-jack
    pavucontrol
)
pacman -S --noconfirm --needed "${AUDIO_PACKAGES[@]}"
log_success "PipeWire audio subsystem installed."

# ------------------------------------------------------------------------------
# 7. Kernel Early KMS & Initramfs Generation
# ------------------------------------------------------------------------------
log_step "Configuring Early KMS & Generating Initramfs"

if [[ -f "${CONFIGS_DIR}/boot/mkinitcpio.conf" ]]; then
    cp "${CONFIGS_DIR}/boot/mkinitcpio.conf" /etc/mkinitcpio.conf
else
    # Fallback template
    cat <<EOF > /etc/mkinitcpio.conf
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block btrfs filesystems fsck)
COMPRESSION="zstd"
EOF
fi

# Dynamically set MODULES based on detected GPU KMS modules
if [[ -n "${KMS_MODULES:-}" ]]; then
    sed -i "s/^MODULES=.*/MODULES=(${KMS_MODULES})/" /etc/mkinitcpio.conf
    log_info "Configured Early KMS modules: (${KMS_MODULES})"
else
    sed -i "s/^MODULES=.*/MODULES=()/" /etc/mkinitcpio.conf
    log_info "Configured standard KMS (no early modules required)."
fi

log_info "Generating kernel initramfs (mkinitcpio -P)..."
mkinitcpio -P
log_success "Initramfs generated successfully."

# ------------------------------------------------------------------------------
# 8. GRUB Bootloader & Snapshot Booting (grub-btrfs)
# ------------------------------------------------------------------------------
log_step "Installing & Configuring GRUB Bootloader"

if [[ -f "${CONFIGS_DIR}/boot/grub.default" ]]; then
    cp "${CONFIGS_DIR}/boot/grub.default" /etc/default/grub
else
    cat <<EOF > /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt part_msdos btrfs"
GRUB_TERMINAL_INPUT="console"
GRUB_GFXMODE="auto"
GRUB_GFXPAYLOAD_LINUX="keep"
GRUB_DISABLE_SUBMENU=y
GRUB_DISABLE_OS_PROBER=true
EOF
fi

# Dynamically inject tailored kernel command line flags
if [[ -n "${KERNEL_CMDLINE_EXTRA:-}" ]]; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet ${KERNEL_CMDLINE_EXTRA}\"|" /etc/default/grub
    log_info "Configured GRUB kernel parameters: loglevel=3 quiet ${KERNEL_CMDLINE_EXTRA}"
else
    sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"|' /etc/default/grub
    log_info "Configured standard GRUB kernel parameters: loglevel=3 quiet"
fi

log_info "Installing GRUB EFI bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck

# Deploy Vimix GRUB theme if available
if [[ -d "${CONFIGS_DIR}/boot/grub-themes/Vimix" ]]; then
    log_info "Deploying Vimix GRUB theme..."
    mkdir -p /boot/grub/themes
    cp -r "${CONFIGS_DIR}/boot/grub-themes/Vimix" /boot/grub/themes/
    sed -i 's|^#\?GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/Vimix/theme.txt"|' /etc/default/grub
    if ! grep -q "^GRUB_THEME=" /etc/default/grub; then
        echo 'GRUB_THEME="/boot/grub/themes/Vimix/theme.txt"' >> /etc/default/grub
    fi
    log_success "Vimix GRUB theme configured."
fi

log_info "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

# Enable grub-btrfs daemon to watch for new Btrfs snapshots
if systemctl list-unit-files 2>/dev/null | grep -q grub-btrfsd; then
    systemctl enable grub-btrfsd.service || true
fi
log_success "GRUB bootloader and snapshot watcher configured."

# ------------------------------------------------------------------------------
# 9. Window Manager, Userland & Tools
# ------------------------------------------------------------------------------
log_step "Installing Window Manager (${WM}), Shells & Rice Applications"

COMMON_USERLAND_PACKAGES=(
    # Core X11 Subsystem & Utilities
    xorg-server
    xorg-xinit
    xorg-xrandr
    xorg-xsetroot
    xorg-xrdb
    xorg-xkill
    xorg-xprop

    # Shells & Core Shell Completions
    bash
    bash-completion
    fish

    # Compositor, Menus & Visuals
    picom
    rofi
    feh
    dunst
    scrot
    viewnior
    xsettingsd
    lxappearance
    xfce4-power-manager
    network-manager-applet

    # File Manager & Thumbnail Generation
    thunar
    tumbler
    raw-thumbnailer
    thunar-archive-plugin
    thunar-volman
    ffmpegthumbnailer

    # Audio & Media
    alsa-utils
    mpd
    mpc

    # Fonts & Icons
    ttf-jetbrains-mono-nerd
    ttf-iosevka-nerd
    ttf-fira-code
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    papirus-icon-theme

    # Display Manager
    lightdm
    lightdm-gtk-greeter

    # Applications & Tools
    firefox
    vlc
    "${TEXT_EDITOR:-neovim}"
    mousepad
)

# Terminal Emulators (Install both Alacritty and XFCE4-terminal for full reliability, plus Kitty if selected)
COMMON_USERLAND_PACKAGES+=(alacritty xfce4-terminal)
if [[ "${TERMINAL}" == "kitty" ]]; then
    COMMON_USERLAND_PACKAGES+=(kitty)
fi

# Add WM packages (BSPWM)
WM_PACKAGES=()
if [[ "${WM}" == "bspwm" ]]; then
    WM_PACKAGES=(bspwm sxhkd polybar)
else
    log_error "Unknown WM: '${WM}'. Only 'bspwm' is supported."
    exit 1
fi

pacman -S --noconfirm --needed "${COMMON_USERLAND_PACKAGES[@]}" "${WM_PACKAGES[@]}"

# Configure LightDM and GTK Greeter
if [[ -f /etc/lightdm/lightdm.conf ]]; then
    log_info "Configuring LightDM GTK Greeter & session..."
    if grep -q "^#\?greeter-session=" /etc/lightdm/lightdm.conf; then
        sed -i 's/^#\?greeter-session=.*/greeter-session=lightdm-gtk-greeter/' /etc/lightdm/lightdm.conf
    else
        sed -i '/^\[Seat:\*\]/a greeter-session=lightdm-gtk-greeter' /etc/lightdm/lightdm.conf
    fi
    if grep -q "^#\?user-session=" /etc/lightdm/lightdm.conf; then
        sed -i 's/^#\?user-session=.*/user-session=bspwm/' /etc/lightdm/lightdm.conf
    fi
fi

# Ensure BSPWM desktop session entry exists for display managers
mkdir -p /usr/share/xsessions
if [[ ! -f /usr/share/xsessions/bspwm.desktop ]]; then
    cat <<'EOF' > /usr/share/xsessions/bspwm.desktop
[Desktop Entry]
Name=bspwm
Comment=Binary space partitioning window manager
Exec=bspwm
Type=Application
EOF
fi

# Configure system-wide default text editor environment
mkdir -p /etc/profile.d
cat <<EOF > /etc/profile.d/editor.sh
export EDITOR="${TEXT_EDITOR:-neovim}"
export VISUAL="${TEXT_EDITOR:-neovim}"
EOF
chmod +x /etc/profile.d/editor.sh

log_success "Window manager, LightDM, desktop applications & utilities installed."

# ------------------------------------------------------------------------------
# 10. User Provisioning & Permissions
# ------------------------------------------------------------------------------
log_step "Provisioning User (${USERNAME}) and Privileges"

# Set root password
log_info "Setting root password..."
if [[ -n "${ROOT_PASSWORD}" ]]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd
else
    echo "Enter root password:"
    passwd root
fi

# Ensure bash and fish are registered in /etc/shells
for _sh in /usr/bin/bash /bin/bash /usr/bin/fish; do
    if [[ -x "$_sh" ]] && ! grep -q "^${_sh}$" /etc/shells; then
        echo "$_sh" >> /etc/shells
    fi
done

# Resolve desired login shell
USER_SHELL="/usr/bin/bash"
if [[ "${DEFAULT_SHELL:-fish}" == "fish" ]] && command -v fish >/dev/null 2>&1; then
    USER_SHELL="$(command -v fish)"
elif command -v "${DEFAULT_SHELL:-bash}" >/dev/null 2>&1; then
    USER_SHELL="$(command -v "${DEFAULT_SHELL:-bash}")"
fi

# Create non-root user
if ! id "${USERNAME}" > /dev/null 2>&1; then
    log_info "Creating user '${USERNAME}' with shell '${USER_SHELL}'..."
    useradd -m -g users -G wheel,video,audio,input,storage,optical -s "${USER_SHELL}" "${USERNAME}"
else
    log_info "Updating user '${USERNAME}' shell to '${USER_SHELL}'..."
    usermod -s "${USER_SHELL}" "${USERNAME}"
fi

log_info "Setting password for user '${USERNAME}'..."
if [[ -n "${USER_PASSWORD}" ]]; then
    echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
else
    echo "Enter password for user '${USERNAME}':"
    passwd "${USERNAME}"
fi

# Enable sudo for wheel group
log_info "Configuring sudo privileges for %wheel..."
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# ------------------------------------------------------------------------------
# 10b. Paru AUR Helper Verification / Userland Build Fallback
# ------------------------------------------------------------------------------
if [[ "${INSTALL_PARU:-true}" == "true" ]]; then
    if ! command -v paru >/dev/null 2>&1; then
        log_info "Paru not yet installed via binary package. Attempting AUR fallback compilation as user '${USERNAME}'..."
        PARU_BUILD_DIR="/tmp/paru-bin-build"
        rm -rf "${PARU_BUILD_DIR}"
        mkdir -p "${PARU_BUILD_DIR}"
        chown -R "${USERNAME}:users" "${PARU_BUILD_DIR}"
        su - "${USERNAME}" -c "git clone --depth=1 https://aur.archlinux.org/paru-bin.git '${PARU_BUILD_DIR}' && cd '${PARU_BUILD_DIR}' && makepkg -si --noconfirm" 2>/dev/null || true
        rm -rf "${PARU_BUILD_DIR}"
    fi

    if command -v paru >/dev/null 2>&1; then
        log_success "Paru AUR helper is installed and verified at $(command -v paru)."
    else
        log_warn "Paru could not be installed automatically; it can be installed post-boot via 'pacman -S paru' once network is active."
    fi
fi

# ------------------------------------------------------------------------------
# 10c. Default AUR & Developer Tools (antigravity-cli)
# ------------------------------------------------------------------------------
if [[ "${INSTALL_ANTIGRAVITY_CLI:-true}" == "true" ]]; then
    log_step "Installing Default Developer Tools (antigravity-cli)"
    log_info "Attempting installation of antigravity-cli..."

    # 1. Check if available directly via Chaotic-AUR binary repository
    if pacman -S --noconfirm --needed antigravity-cli 2>/dev/null; then
        log_success "antigravity-cli installed via repository."
    elif command -v paru >/dev/null 2>&1; then
        # 2. Try building/installing via Paru as the non-root user
        log_info "Installing antigravity-cli from AUR using paru..."
        if su - "${USERNAME}" -c "paru -S --noconfirm --needed antigravity-cli" 2>/dev/null; then
            log_success "antigravity-cli installed successfully via paru."
        else
            log_warn "paru installation of antigravity-cli encountered an issue; attempting direct makepkg fallback."
        fi
    fi

    # 3. Direct AUR makepkg fallback compilation if not yet installed
    if ! command -v antigravity-cli >/dev/null 2>&1 && ! command -v agy >/dev/null 2>&1; then
        log_info "Attempting direct AUR git clone build of antigravity-cli..."
        AGY_BUILD_DIR="/tmp/antigravity-cli-build"
        rm -rf "${AGY_BUILD_DIR}"
        mkdir -p "${AGY_BUILD_DIR}"
        chown -R "${USERNAME}:users" "${AGY_BUILD_DIR}"
        if su - "${USERNAME}" -c "git clone --depth=1 https://aur.archlinux.org/antigravity-cli.git '${AGY_BUILD_DIR}' && cd '${AGY_BUILD_DIR}' && makepkg -si --noconfirm" 2>/dev/null; then
            log_success "antigravity-cli built and installed from AUR."
        else
            log_warn "antigravity-cli could not be built automatically (may require network or can be installed post-boot via 'paru -S antigravity-cli')."
        fi
        rm -rf "${AGY_BUILD_DIR}"
    fi

    if command -v antigravity-cli >/dev/null 2>&1 || command -v agy >/dev/null 2>&1; then
        log_success "antigravity-cli verified successfully."
    fi
fi

# ------------------------------------------------------------------------------
# 11. Dotfiles & Desktop Configuration Deployment
# ------------------------------------------------------------------------------
log_step "Deploying Idiomatic Dotfiles & Community Desktop Rice for ${USERNAME}"

USER_HOME="/home/${USERNAME}"
USER_CONFIG="${USER_HOME}/.config"
DOTFILES_SRC="${CONFIGS_DIR}/dotfiles"

# Automatically fetch/refresh latest community dotfiles if requested and network is reachable
if [[ "${AUTO_INSTALL_DOTFILES:-true}" == "true" && -n "${DOTFILES_REPO_URL:-}" ]]; then
    log_info "Checking for remote community dotfiles (${DOTFILES_REPO_URL})..."
    DOTFILES_CLONE_DIR="/tmp/community-dotfiles-repo"
    rm -rf "${DOTFILES_CLONE_DIR}"
    if git clone --depth=1 "${DOTFILES_REPO_URL}" "${DOTFILES_CLONE_DIR}" 2>/dev/null; then
        log_success "Successfully fetched remote community dotfiles from GitHub."
        if [[ -d "${DOTFILES_CLONE_DIR}/dotfiles" ]]; then
            cp -rf "${DOTFILES_CLONE_DIR}/dotfiles/." "${DOTFILES_SRC}/" 2>/dev/null || true
        fi
        rm -rf "${DOTFILES_CLONE_DIR}"
    else
        log_info "Remote repository unavailable; utilizing local pre-bundled community dotfiles."
    fi
fi

# Ensure all target user configuration directories exist
mkdir -p "${USER_CONFIG}"/{bspwm,sxhkd,polybar,rofi,kitty,alacritty,dunst,fish,picom}
mkdir -p "${USER_HOME}"/{.local/bin,Pictures,Documents,Downloads,.Xresources.d}

# 1. Shell Configurations (Bash & Fish)
log_info "Deploying shell configurations (bash & fish)..."
if [[ -f "${DOTFILES_SRC}/bash/.bashrc" ]]; then
    cp "${DOTFILES_SRC}/bash/.bashrc" "${USER_HOME}/.bashrc"
fi
if [[ -f "${DOTFILES_SRC}/bash/.bash_profile" ]]; then
    cp "${DOTFILES_SRC}/bash/.bash_profile" "${USER_HOME}/.bash_profile"
fi
if [[ -f "${DOTFILES_SRC}/fish/config.fish" ]]; then
    cp "${DOTFILES_SRC}/fish/config.fish" "${USER_CONFIG}/fish/config.fish"
fi

# 2. Window Manager & Ricing Suites (BSPWM, SXHKD, Polybar, Dunst, Rofi)
log_info "Deploying BSPWM, SXHKD, Polybar, Dunst & Rofi suites..."
if [[ -d "${DOTFILES_SRC}/bspwm" ]]; then
    cp -rf "${DOTFILES_SRC}/bspwm/." "${USER_CONFIG}/bspwm/"
fi
if [[ -d "${DOTFILES_SRC}/sxhkd" ]]; then
    cp -rf "${DOTFILES_SRC}/sxhkd/." "${USER_CONFIG}/sxhkd/"
fi
if [[ -d "${DOTFILES_SRC}/polybar" ]]; then
    cp -rf "${DOTFILES_SRC}/polybar/." "${USER_CONFIG}/polybar/"
fi
if [[ -d "${DOTFILES_SRC}/rofi" ]]; then
    cp -rf "${DOTFILES_SRC}/rofi/." "${USER_CONFIG}/rofi/"
fi
if [[ -d "${DOTFILES_SRC}/dunst" ]]; then
    cp -rf "${DOTFILES_SRC}/dunst/." "${USER_CONFIG}/dunst/"
fi

# 3. Terminal Emulator Configurations (Alacritty & Kitty)
log_info "Deploying terminal configurations (Alacritty & Kitty)..."
if [[ -d "${DOTFILES_SRC}/alacritty" ]]; then
    cp -rf "${DOTFILES_SRC}/alacritty/." "${USER_CONFIG}/alacritty/"
fi
if [[ -f "${USER_CONFIG}/bspwm/alacritty/alacritty.toml" ]]; then
    cp "${USER_CONFIG}/bspwm/alacritty/alacritty.toml" "${USER_CONFIG}/alacritty/alacritty.toml"
fi
if [[ -d "${DOTFILES_SRC}/kitty" ]]; then
    cp -rf "${DOTFILES_SRC}/kitty/." "${USER_CONFIG}/kitty/"
fi

# 4. Picom Compositor Configuration
if [[ -f "${DOTFILES_SRC}/picom/picom.conf" ]]; then
    cp "${DOTFILES_SRC}/picom/picom.conf" "${USER_CONFIG}/picom/picom.conf"
fi
if [[ -f "${USER_CONFIG}/bspwm/compton.conf" && ! -f "${USER_CONFIG}/picom/picom.conf" ]]; then
    cp "${USER_CONFIG}/bspwm/compton.conf" "${USER_CONFIG}/picom/picom.conf"
fi

# 5. Xresources, Theming & Desktop Session Files
if [[ -d "${DOTFILES_SRC}/Xresources/.Xresources.d" ]]; then
    cp -rf "${DOTFILES_SRC}/Xresources/.Xresources.d/." "${USER_HOME}/.Xresources.d/"
fi
if [[ -f "${DOTFILES_SRC}/Xresources/.Xresources" ]]; then
    cp "${DOTFILES_SRC}/Xresources/.Xresources" "${USER_HOME}/.Xresources"
elif [[ -f "${DOTFILES_SRC}/.Xresources" ]]; then
    cp "${DOTFILES_SRC}/.Xresources" "${USER_HOME}/.Xresources"
fi

# Pre-populate default Nord colors if missing
if [[ ! -f "${USER_HOME}/.Xresources.d/colors" && -f "${USER_CONFIG}/bspwm/themes/nord" ]]; then
    cp "${USER_CONFIG}/bspwm/themes/nord" "${USER_HOME}/.Xresources.d/colors"
fi

# Supporting user environment files
[[ -f "${DOTFILES_SRC}/.xsettingsd" ]] && cp "${DOTFILES_SRC}/.xsettingsd" "${USER_HOME}/.xsettingsd"
[[ -f "${DOTFILES_SRC}/.fehbg" ]] && cp "${DOTFILES_SRC}/.fehbg" "${USER_HOME}/.fehbg"
[[ -f "${DOTFILES_SRC}/.vimrc" ]] && cp "${DOTFILES_SRC}/.vimrc" "${USER_HOME}/.vimrc"
[[ -f "${DOTFILES_SRC}/xinitrc" ]] && cp "${DOTFILES_SRC}/xinitrc" "${USER_HOME}/.xinitrc"

# 6. Ensure Execution Bits on All Scripts
log_info "Configuring execution permissions for scripts..."
chmod +x "${USER_CONFIG}/bspwm/bspwmrc" 2>/dev/null || true
chmod +x "${USER_CONFIG}/bspwm/bin/"* 2>/dev/null || true
chmod +x "${USER_CONFIG}/bspwm/rofi/bin/"* 2>/dev/null || true
chmod +x "${USER_CONFIG}/bspwm/themes/set-theme" 2>/dev/null || true
chmod +x "${USER_CONFIG}/polybar/launch.sh" 2>/dev/null || true
chmod +x "${USER_CONFIG}/dunst/"*.sh 2>/dev/null || true
chmod +x "${USER_HOME}/.fehbg" 2>/dev/null || true
chmod +x "${USER_HOME}/.xinitrc" 2>/dev/null || true

# 7. Pre-synchronize Colors for First Login
if [[ -x "${USER_CONFIG}/bspwm/bin/bspcolors" ]]; then
    su - "${USERNAME}" -c "bash ${USER_CONFIG}/bspwm/bin/bspcolors" 2>/dev/null || true
fi

# 8. Adaptive Hardware Customization for Polybar
# Dynamically adapt primary network interface
PRIMARY_NET_IFACE="$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ "lo|vir|docker" {print $2; exit}' || echo "")"
if [[ -n "$PRIMARY_NET_IFACE" ]]; then
    for _pcfg in "${USER_CONFIG}/bspwm/polybar/config" "${USER_CONFIG}/polybar/config.ini"; do
        if [[ -f "$_pcfg" ]]; then
            sed -i "s/interface = wlan0/interface = ${PRIMARY_NET_IFACE}/" "$_pcfg"
        fi
    done
    log_info "Configured Polybar network interface to '${PRIMARY_NET_IFACE}'."
fi

# Tailor Polybar battery module based on detected battery presence
for _pcfg in "${USER_CONFIG}/polybar/config.ini" "${USER_CONFIG}/bspwm/polybar/config"; do
    [[ ! -f "$_pcfg" ]] && continue
    if [[ "${HAS_BATTERY:-0}" -eq 1 ]]; then
        if [[ -n "${BATTERY_NAME:-}" ]]; then
            sed -i "s/^battery = BAT[0-9]/battery = ${BATTERY_NAME}/" "$_pcfg"
        fi
        if [[ -n "${ADAPTER_NAME:-}" ]]; then
            sed -i "s/^adapter = .*/adapter = ${ADAPTER_NAME}/" "$_pcfg"
        fi
        log_info "Polybar battery module configured for ${BATTERY_NAME:-BAT0} and ${ADAPTER_NAME:-AC}."
    else
        sed -i 's/modules-right = cpu memory filesystem backlight battery network volume date/modules-right = cpu memory filesystem network volume date/' "$_pcfg"
        sed -i 's/modules-right = cpu memory battery pulseaudio date/modules-right = cpu memory pulseaudio date/' "$_pcfg"
        log_info "Battery not present; disabled battery module in Polybar."
    fi
done

# 9. Finalize Ownership
chown -R "${USERNAME}:users" "${USER_HOME}"
log_success "Community dotfiles deployed to ${USER_HOME}/.config/ and permissions set."

# ------------------------------------------------------------------------------
# 12. System Services Enablement
# ------------------------------------------------------------------------------
log_step "Enabling System Daemons"

systemctl enable NetworkManager.service

if [[ "${DISPLAY_MANAGER}" == "lightdm" ]]; then
    systemctl enable lightdm.service
    log_info "Display manager (lightdm) enabled."
elif [[ "${DISPLAY_MANAGER}" == "sddm" ]]; then
    systemctl enable sddm.service
    log_info "Display manager (sddm) enabled."
fi

log_success "Stage 2 configuration completed successfully!"
