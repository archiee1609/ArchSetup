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
# 2. Pacman Optimization & Multilib Activation
# ------------------------------------------------------------------------------
log_step "Configuring Pacman & Repositories"

# Enable ParallelDownloads, Color, and Multilib
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    log_info "Activating multilib repository..."
    cat <<EOF >> /etc/pacman.conf

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
fi

pacman -Sy --noconfirm archlinux-keyring

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

log_info "Installing tailored graphics drivers: ${GRAPHICS_PACKAGES[*]}"
pacman -S --noconfirm --needed "${GRAPHICS_PACKAGES[@]}"

# Deploy PRIME Run Script tailored to GPU architecture
log_info "Configuring prime-run wrapper (/usr/local/bin/prime-run)..."
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
log_step "Installing Window Manager (${WM}) & Userland Applications"

COMMON_USERLAND_PACKAGES=(
    xorg-server
    xorg-xinit
    xorg-xrandr
    xorg-xsetroot
    picom
    rofi
    feh
    ttf-jetbrains-mono-nerd
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    papirus-icon-theme
    sddm
)

# Add selected terminal
if [[ "${TERMINAL}" == "kitty" ]]; then
    COMMON_USERLAND_PACKAGES+=(kitty)
elif [[ "${TERMINAL}" == "alacritty" ]]; then
    COMMON_USERLAND_PACKAGES+=(alacritty)
else
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
log_success "Window manager and desktop utilities installed."

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

# Create non-root user
if ! id "${USERNAME}" > /dev/null 2>&1; then
    log_info "Creating user '${USERNAME}'..."
    useradd -m -g users -G wheel,video,audio,input,storage,optical -s /bin/bash "${USERNAME}"
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
# 11. Dotfiles & Desktop Configuration Deployment
# ------------------------------------------------------------------------------
log_step "Deploying Idiomatic Dotfiles for ${USERNAME}"

USER_HOME="/home/${USERNAME}"
USER_CONFIG="${USER_HOME}/.config"

mkdir -p "${USER_CONFIG}"/{picom,rofi,kitty,alacritty,bspwm,sxhkd,polybar}

# Deploy Picom
cp "${CONFIGS_DIR}/dotfiles/picom/picom.conf" "${USER_CONFIG}/picom/picom.conf"

# Deploy Rofi
cp "${CONFIGS_DIR}/dotfiles/rofi/config.rasi" "${USER_CONFIG}/rofi/config.rasi"

# Deploy Terminals
cp "${CONFIGS_DIR}/dotfiles/kitty/kitty.conf" "${USER_CONFIG}/kitty/kitty.conf"
cp "${CONFIGS_DIR}/dotfiles/alacritty/alacritty.toml" "${USER_CONFIG}/alacritty/alacritty.toml"

# Deploy BSPWM / SXHKD / Polybar
cp "${CONFIGS_DIR}/dotfiles/bspwm/bspwmrc" "${USER_CONFIG}/bspwm/bspwmrc"
chmod +x "${USER_CONFIG}/bspwm/bspwmrc"

cp "${CONFIGS_DIR}/dotfiles/sxhkd/sxhkdrc" "${USER_CONFIG}/sxhkd/sxhkdrc"
cp "${CONFIGS_DIR}/dotfiles/polybar/config.ini" "${USER_CONFIG}/polybar/config.ini"
cp "${CONFIGS_DIR}/dotfiles/polybar/launch.sh" "${USER_CONFIG}/polybar/launch.sh"
chmod +x "${USER_CONFIG}/polybar/launch.sh"

# Tailor Polybar battery module based on detected battery presence
if [[ "${HAS_BATTERY:-0}" -eq 1 ]]; then
    if [[ -n "${BATTERY_NAME:-}" ]]; then
        sed -i "s/^battery = BAT0/battery = ${BATTERY_NAME}/" "${USER_CONFIG}/polybar/config.ini"
    fi
    if [[ -n "${ADAPTER_NAME:-}" ]]; then
        sed -i "s/^adapter = ADP1/adapter = ${ADAPTER_NAME}/" "${USER_CONFIG}/polybar/config.ini"
    fi
    log_info "Polybar battery module configured for ${BATTERY_NAME:-BAT0} and ${ADAPTER_NAME:-AC}."
else
    # Remove battery module from top bar on desktop or VM
    sed -i 's/modules-right = cpu memory battery pulseaudio date/modules-right = cpu memory pulseaudio date/' "${USER_CONFIG}/polybar/config.ini"
    log_info "Battery not present; disabled battery module in Polybar."
fi

# Deploy xinitrc fallback
cp "${CONFIGS_DIR}/dotfiles/xinitrc" "${USER_HOME}/.xinitrc"
chmod +x "${USER_HOME}/.xinitrc"

# Fix permissions
chown -R "${USERNAME}:users" "${USER_HOME}"
log_success "Dotfiles deployed to ${USER_HOME}/.config/."

# ------------------------------------------------------------------------------
# 12. System Services Enablement
# ------------------------------------------------------------------------------
log_step "Enabling System Daemons"

systemctl enable NetworkManager.service

if [[ "${DISPLAY_MANAGER}" == "sddm" ]]; then
    systemctl enable sddm.service
    log_info "Display manager (sddm) enabled."
fi

log_success "Stage 2 configuration completed successfully!"
