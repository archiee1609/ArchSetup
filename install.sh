#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Master Automated / Modular Installer
# Adaptive Hardware Profiling & Deployment Suite
# Automatically detects system specifications and tunes installation accordingly.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library and configurations
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/lib/common.sh"
else
    echo "ERROR: lib/common.sh not found!" >&2
    exit 1
fi

if [[ -f "${SCRIPT_DIR}/lib/detect.sh" ]]; then
    # shellcheck source=lib/detect.sh
    source "${SCRIPT_DIR}/lib/detect.sh"
fi

if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck source=config.env
    source "${SCRIPT_DIR}/config.env"
fi

print_banner() {
    cat << "EOF"
================================================================================
    _             _      _     _                  ___           _        _ _ 
   / \   _ __ ___| |__  | |   (_)_ __  _   ___  _|_ _|_ __  ___| |_ __ _| | |
  / _ \ | '__/ __| '_ \ | |   | | '_ \| | | \ \/ /| || '_ \/ __| __/ _` | | |
 / ___ \| | | (__| | | || |___| | | | | |_| |>  < | || | | \__ \ || (_| | | |
/_/   \_\_|  \___|_| |_||_____|_|_| |_|\__,_/_/\_\___|_| |_|___/\__\__,_|_|_|
================================================================================
        Adaptive Hardware-Aware Installer & Deployment Suite
================================================================================
EOF
}

show_summary() {
    echo -e "${CLR_STEP}Installation & Target Configuration Summary:${CLR_RESET}"
    echo -e "  Storage Target Mode:        ${CLR_BOLD}${DISK_LAYOUT:-single}${CLR_RESET} ($([[ "${DISK_LAYOUT:-single}" == "all" ]] && echo "Partition all detected drives" || echo "Single target drive only"))"
    echo -e "  Primary Storage (DISK1):    ${CLR_BOLD}${DISK1}${CLR_RESET}"
    if [[ "${DISK_LAYOUT:-single}" == "all" && -n "${DISK2:-}" ]]; then
        echo -e "  Secondary Storage (DISK2):  ${CLR_BOLD}${DISK2}${CLR_RESET}"
    else
        echo -e "  Secondary Storage:          ${CLR_DIM}None (Single-Disk Layout)${CLR_RESET}"
    fi
    echo -e "  Filesystem / Scheme:        ${CLR_BOLD}${FILESYSTEM:-btrfs}${CLR_RESET}"
    if [[ "${FILESYSTEM:-btrfs}" == "btrfs" ]]; then
        if [[ "${DISK_LAYOUT:-single}" == "all" && -n "${DISK2:-}" ]]; then
            echo -e "  Btrfs Pool Strategy:        ${CLR_BOLD}${BTRFS_MODE}${CLR_RESET}"
        else
            echo -e "  Btrfs Storage Mode:         ${CLR_BOLD}single_disk${CLR_RESET}"
        fi
        echo -e "  Mount Options:              ${BTRFS_MOUNT_OPTS}"
    elif [[ "${FILESYSTEM}" == "ext4" ]]; then
        echo -e "  Mount Options:              ${EXT4_MOUNT_OPTS:-noatime,errors=remount-ro}"
    elif [[ "${FILESYSTEM}" == "xfs" ]]; then
        echo -e "  Mount Options:              ${XFS_MOUNT_OPTS:-noatime}"
    elif [[ "${FILESYSTEM}" == "f2fs" ]]; then
        echo -e "  Mount Options:              ${F2FS_MOUNT_OPTS:-noatime}"
    fi
    echo -e "  Processor (CPU):            ${CLR_BOLD}${DETECTED_CPU_MODEL:-Standard x86_64}${CLR_RESET}"
    echo -e "  Microcode Package:          ${CLR_BOLD}${CPU_UCODE_PACKAGE:-None}${CLR_RESET}"
    echo -e "  System Memory (RAM):        ${DETECTED_RAM_GB:-Unknown} (ZRAM: ${ZRAM_FRACTION:-0.5} ${ZRAM_ALGORITHM:-zstd})"
    echo -e "  Platform Architecture:      ${CLR_BOLD}${CHASSIS_TYPE:-standard}${CLR_RESET} (Virtualization: ${VIRT_TYPE:-none})"
    echo -e "  Graphics Stack:             ${CLR_BOLD}${DETECTED_GPU_SETUP:-generic}${CLR_RESET}"
    echo -e "  Early KMS Modules:          ${KMS_MODULES:-None (Standard KMS)}"
    if [[ -n "${KERNEL_CMDLINE_EXTRA:-}" ]]; then
        echo -e "  Kernel Parameters:          ${KERNEL_CMDLINE_EXTRA}"
    fi
    echo -e "  PRIME Offloading:           ${PRIME_TYPE:-none}"
    echo -e "  Multilib Repository:        ${CLR_BOLD}$([[ "${ENABLE_MULTILIB:-true}" == "true" ]] && echo "Enabled" || echo "Disabled")${CLR_RESET}"
    echo -e "  Chaotic-AUR Repository:     ${CLR_BOLD}$([[ "${ENABLE_CHAOTIC_AUR:-true}" == "true" ]] && echo "Enabled" || echo "Disabled")${CLR_RESET}"
    echo -e "  AUR Helper:                 ${CLR_BOLD}$([[ "${INSTALL_PARU:-true}" == "true" ]] && echo "paru" || echo "None")${CLR_RESET}"
    echo -e "  Timezone / Locale:          ${TIMEZONE} / ${LOCALE}"
    echo -e "  Target Hostname:            ${HOSTNAME}"
    echo -e "  Primary User:               ${USERNAME}"
    echo -e "  Desktop Environment:        ${CLR_BOLD}${DESKTOP_ENV:-bspwm}${CLR_RESET}"
    echo -e "  Display Manager:            ${CLR_BOLD}${DISPLAY_MANAGER}${CLR_RESET}"
    echo -e "  Terminal Emulator:          ${TERMINAL}"
    echo -e "  Default Web Browser:        ${BROWSER:-firefox}"
    echo -e "  Default Text Editor:        ${TEXT_EDITOR:-neovim} / mousepad"
    echo -e "================================================================================"
}

run_interactive_wizard() {
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}             ARCHSETUP INTERACTIVE CONFIGURATION WIZARD              ${CLR_RESET}"
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"

    # ----------------------------------------------------------------------
    # 1. Target Disk Selection (Single Disk vs All Disks)
    # ----------------------------------------------------------------------
    echo -e "\n${CLR_STEP}--> [1/3] Storage Target Layout Selection${CLR_RESET}"
    echo -e "Detected Storage Devices (${DETECTED_DISK_COUNT} found):"
    for i in "${!DETECTED_DISK_DETAILS[@]}"; do
        echo -e "  [$((i + 1))] ${DETECTED_DISK_DETAILS[$i]}"
    done
    echo ""
    echo -e "Select how you would like to partition your drive(s):"
    echo -e "  ${CLR_BOLD}1) Single Disk${CLR_RESET} - Install entirely onto one disk (preserves all other disks)"
    echo -e "  ${CLR_BOLD}2) All Disks${CLR_RESET}   - Partition and pool/use all detected storage disks"

    local default_layout="1"
    if [[ "${DISK_LAYOUT:-}" == "all" && "$DETECTED_DISK_COUNT" -ge 2 ]]; then
        default_layout="2"
    fi
    read -rp "Enter choice [1 or 2, Default: ${default_layout}]: " DISK_CHOICE
    DISK_CHOICE="${DISK_CHOICE:-$default_layout}"

    if [[ "$DISK_CHOICE" == "2" && "$DETECTED_DISK_COUNT" -ge 2 ]]; then
        DISK_LAYOUT="all"
        DISK1="${DETECTED_DISKS[0]}"
        DISK2="${DETECTED_DISKS[1]}"
        log_info "Selected layout: All Disks (Primary: ${DISK1}, Secondary: ${DISK2})"
    else
        DISK_LAYOUT="single"
        DISK2=""
        BTRFS_MODE="single_disk"
        if [[ "$DETECTED_DISK_COUNT" -gt 1 ]]; then
            echo -e "\nSelect which drive to install Arch Linux on:"
            for i in "${!DETECTED_DISK_DETAILS[@]}"; do
                echo -e "  [$((i + 1))] ${DETECTED_DISK_DETAILS[$i]}"
            done
            read -rp "Enter disk number [1-${DETECTED_DISK_COUNT}, Default: 1]: " TARGET_DISK_IDX
            TARGET_DISK_IDX="${TARGET_DISK_IDX:-1}"
            if [[ "$TARGET_DISK_IDX" =~ ^[0-9]+$ ]] && (( TARGET_DISK_IDX >= 1 && TARGET_DISK_IDX <= DETECTED_DISK_COUNT )); then
                DISK1="${DETECTED_DISKS[$((TARGET_DISK_IDX - 1))]}"
            else
                DISK1="${DETECTED_PRIMARY_DISK:-/dev/sda}"
            fi
        else
            DISK1="${DETECTED_PRIMARY_DISK:-/dev/sda}"
        fi
        log_info "Selected target drive: ${DISK1} (Single Disk Layout)"
    fi

    # ----------------------------------------------------------------------
    # 2. Partition Scheme & Filesystem Selection
    # ----------------------------------------------------------------------
    echo -e "\n${CLR_STEP}--> [2/3] Partition Scheme & Filesystem Selection${CLR_RESET}"
    echo -e "Select partition scheme and filesystem for root:"
    echo -e "  ${CLR_BOLD}1) btrfs${CLR_RESET} (Default) - Subvolumes (@, @home, @snapshots), zstd compression, snapshots"
    echo -e "  ${CLR_BOLD}2) ext4${CLR_RESET}          - Standard Linux filesystem (rock-solid, mature, journaling)"
    echo -e "  ${CLR_BOLD}3) xfs${CLR_RESET}           - High-performance enterprise 64-bit journaling filesystem"
    echo -e "  ${CLR_BOLD}4) f2fs${CLR_RESET}          - Flash-Friendly File System (optimized for SSDs & NVMe)"

    local default_fs="1"
    case "${FILESYSTEM:-btrfs}" in
        ext4) default_fs="2" ;;
        xfs)  default_fs="3" ;;
        f2fs) default_fs="4" ;;
        *)    default_fs="1" ;;
    esac
    read -rp "Enter choice [1-4, Default: ${default_fs}]: " FS_CHOICE
    FS_CHOICE="${FS_CHOICE:-$default_fs}"

    case "$FS_CHOICE" in
        2) FILESYSTEM="ext4" ;;
        3) FILESYSTEM="xfs" ;;
        4) FILESYSTEM="f2fs" ;;
        *) FILESYSTEM="btrfs" ;;
    esac
    FS_TYPE="${FILESYSTEM}"
    log_info "Selected filesystem: ${FILESYSTEM}"

    if [[ "${FILESYSTEM}" == "btrfs" && "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
        echo -e "\nSelect Btrfs Multi-Device Pool Strategy:"
        echo -e "  ${CLR_BOLD}1) raid0${CLR_RESET}    - Striped data pool across both SSDs for maximum throughput"
        echo -e "  ${CLR_BOLD}2) single${CLR_RESET}   - Linear concatenation spanning drives"
        echo -e "  ${CLR_BOLD}3) separate${CLR_RESET} - Standalone root on primary disk, secondary drive mounted at /data"
        read -rp "Enter choice [1-3, Default: 1]: " BTRFS_CHOICE
        case "${BTRFS_CHOICE:-1}" in
            2) BTRFS_MODE="single" ;;
            3) BTRFS_MODE="separate" ;;
            *) BTRFS_MODE="raid0" ;;
        esac
        log_info "Selected Btrfs pool strategy: ${BTRFS_MODE}"
    fi

    # ----------------------------------------------------------------------
    # 3. Desktop Environment & Display Manager Selection
    # ----------------------------------------------------------------------
    echo -e "\n${CLR_STEP}--> [3/3] Desktop Environment & Display Manager Selection${CLR_RESET}"
    echo -e "Select graphical desktop interface:"
    echo -e "  ${CLR_BOLD}1) bspwm${CLR_RESET} - Minimalist tiling window manager + LightDM display manager + Polybar + Rofi + Dunst"
    echo -e "  ${CLR_BOLD}2) gnome${CLR_RESET} - Modern full-featured GNOME desktop environment + GDM display manager"

    local default_de="1"
    if [[ "${DESKTOP_ENV:-}" == "gnome" ]]; then
        default_de="2"
    fi
    read -rp "Enter choice [1 or 2, Default: ${default_de}]: " DE_CHOICE
    DE_CHOICE="${DE_CHOICE:-$default_de}"

    if [[ "$DE_CHOICE" == "2" ]]; then
        DESKTOP_ENV="gnome"
        WM="gnome"
        DISPLAY_MANAGER="gdm"
        log_info "Selected Desktop: GNOME (Display Manager: GDM)"
    else
        DESKTOP_ENV="bspwm"
        WM="bspwm"
        DISPLAY_MANAGER="lightdm"
        log_info "Selected Desktop: BSPWM (Display Manager: LightDM)"
    fi
    echo -e "${CLR_STEP}----------------------------------------------------------------------${CLR_RESET}\n"
}

main() {
    local explicit_interactive=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-d)
                export DRY_RUN=1
                shift
                ;;
            --interactive|-i)
                explicit_interactive="true"
                shift
                ;;
            --non-interactive|--batch|-y)
                explicit_interactive="false"
                shift
                ;;
            --disk-layout)
                DISK_LAYOUT="$2"
                shift 2
                ;;
            --disk)
                DISK1="$2"
                shift 2
                ;;
            --fs|--filesystem)
                FILESYSTEM="$2"
                FS_TYPE="$2"
                shift 2
                ;;
            --desktop|--de|--wm)
                DESKTOP_ENV="$2"
                WM="$2"
                shift 2
                ;;
            --display-manager|--dm)
                DISPLAY_MANAGER="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --dry-run, -d              : Perform simulated validation without disk changes"
                echo "  --interactive, -i          : Display interactive configuration wizard"
                echo "  --non-interactive, -y      : Run non-interactively using config.env / arguments"
                echo "  --disk-layout <single|all> : Choose single-disk or all-disks target layout"
                echo "  --disk <device>            : Specify primary target drive (e.g. /dev/sda, /dev/nvme0n1)"
                echo "  --fs <btrfs|ext4|xfs|f2fs> : Choose root filesystem / partition scheme"
                echo "  --desktop <bspwm|gnome>    : Choose desktop environment"
                echo "  --display-manager <dm>     : Choose display manager (lightdm, gdm)"
                echo "  --help, -h                 : Show this help message"
                exit 0
                ;;
            *)
                log_warn "Unknown argument: $1"
                shift
                ;;
        esac
    done

    # Determine interactive status
    if [[ -n "$explicit_interactive" ]]; then
        INTERACTIVE="$explicit_interactive"
    elif [[ -t 0 && "${DRY_RUN:-0}" != "1" ]]; then
        INTERACTIVE="${INTERACTIVE:-true}"
    else
        INTERACTIVE="false"
    fi

    clear 2>/dev/null || true
    print_banner
    check_root
    check_uefi
    check_network

    # Automatically probe hardware specifications if enabled
    if [[ "${AUTO_DETECT_HARDWARE:-true}" == "true" ]]; then
        log_step "Probing System Hardware Specifications"
        detect_hardware
        apply_hardware_profile
        print_hardware_report
    fi

    # Run interactive wizard if interactive mode is active
    if [[ "${INTERACTIVE}" == "true" ]]; then
        run_interactive_wizard
        apply_hardware_profile
    fi

    # Persist the final configuration into hardware profile
    save_hardware_profile "${SCRIPT_DIR}/hardware.env"

    show_summary

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "DRY-RUN mode enabled. Simulating execution without destructive disk actions."
        "${SCRIPT_DIR}/stage1_disk_base.sh"
        local py_bin="python3"
        if ! command -v python3 >/dev/null 2>&1; then
            if command -v python >/dev/null 2>&1; then
                py_bin="python"
            fi
        fi
        "${py_bin}" "${SCRIPT_DIR}/tests/test_archsetup.py"
        echo ""
        log_success "[DRY-RUN] Full simulation and validation completed successfully!"
        exit 0
    fi

    echo ""
    read -rp "Do you wish to start the installation with these specifications? [y/N]: " PROCEED
    if [[ ! "${PROCEED}" =~ ^[Yy]$ ]]; then
        log_warn "Installation aborted by user."
        exit 0
    fi

    # --------------------------------------------------------------------------
    # Stage 1: Disks, Filesystems, Partitions & Pacstrap
    # --------------------------------------------------------------------------
    log_step "Executing Stage 1: Partitioning, Filesystem Setup & Pacstrap"
    "${SCRIPT_DIR}/stage1_disk_base.sh"

    # --------------------------------------------------------------------------
    # Stage 2: Post-Chroot Configuration
    # --------------------------------------------------------------------------
    log_step "Executing Stage 2: Post-Chroot Configuration"
    arch-chroot /mnt /opt/arch_installer/stage2_chroot.sh

    # --------------------------------------------------------------------------
    # Completion & Post-Install Guidance
    # --------------------------------------------------------------------------
    echo ""
    log_success "Arch Linux installation and environment deployment completed successfully!"
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}Post-Installation Next Steps:${CLR_RESET}"
    echo -e "  1. Unmount all partitions cleanly:  ${CLR_BOLD}umount -R /mnt${CLR_RESET}"
    echo -e "  2. Reboot into your new system:     ${CLR_BOLD}reboot${CLR_RESET}"
    echo -e "  3. Remove your Arch live USB drive."
    echo -e ""
    if [[ "${PRIME_TYPE:-none}" != "none" ]]; then
        echo -e "${CLR_BOLD}PRIME Offload Usage (${PRIME_TYPE}):${CLR_RESET}"
        echo -e "  - Standard desktop apps run on primary display GPU."
        echo -e "  - Offload demanding games/3D apps to discrete GPU via:"
        echo -e "      ${CLR_BOLD}prime-run <command>${CLR_RESET}   (e.g., prime-run vkcube)"
        echo -e ""
    fi
    if [[ "${INSTALL_PARU:-true}" == "true" ]]; then
        echo -e "${CLR_BOLD}AUR & Package Management:${CLR_RESET}"
        echo -e "  - Paru AUR helper is installed:     ${CLR_BOLD}paru <package>${CLR_RESET}"
        echo -e "  - Chaotic-AUR prebuilt binaries are enabled for instant installations."
        echo -e ""
    fi
    echo -e "${CLR_BOLD}Default Software & Desktop Environment:${CLR_RESET}"
    echo -e "  - Desktop Interface: ${CLR_BOLD}${DESKTOP_ENV:-bspwm}${CLR_RESET}"
    echo -e "  - Display Manager:   ${CLR_BOLD}${DISPLAY_MANAGER}${CLR_RESET}"
    echo -e "  - Web Browser:       ${CLR_BOLD}${BROWSER:-firefox}${CLR_RESET}"
    echo -e "  - Media Player:      ${CLR_BOLD}${BROWSER:-vlc}${CLR_RESET}"
    echo -e "  - Text Editors:      ${CLR_BOLD}${TEXT_EDITOR:-neovim}${CLR_RESET} (CLI) & ${CLR_BOLD}Mousepad${CLR_RESET} (GTK GUI)"
    if [[ "${INSTALL_ANTIGRAVITY_CLI:-true}" == "true" ]]; then
        echo -e "  - Developer Tools:   ${CLR_BOLD}antigravity-cli${CLR_RESET} (Run via 'antigravity-cli' or 'agy')"
    fi
    echo -e ""
    if [[ "${FILESYSTEM:-btrfs}" == "btrfs" ]]; then
        echo -e "${CLR_BOLD}Btrfs Snapshot Management:${CLR_RESET}"
        echo -e "  - Snapper/btrfs snapshots taken in /.snapshots are automatically"
        echo -e "    picked up by ${CLR_BOLD}grub-btrfs${CLR_RESET} and displayed in the GRUB boot menu."
    fi
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"
}

main "$@"
