#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Master Automated / Modular Installer
# Target Architecture: Intel Core i5-8250U + AMD Radeon R5 M330 (Oland)
# Storage: Dual SATA SSDs (Btrfs Multi-Device / RAID0 Spanning)
# Window Manager: Qtile / BSPWM
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
      Hardware-Tuned Clean Installer: Intel i5-8250U + AMD Radeon R5 M330
================================================================================
EOF
}

show_summary() {
    echo -e "${CLR_STEP}Configuration Summary:${CLR_RESET}"
    echo -e "  Primary Storage (DISK1):    ${CLR_BOLD}${DISK1}${CLR_RESET}"
    echo -e "  Secondary Storage (DISK2):  ${CLR_BOLD}${DISK2}${CLR_RESET}"
    echo -e "  Btrfs Pool Strategy:        ${CLR_BOLD}${BTRFS_MODE}${CLR_RESET}"
    echo -e "  Mount Options:              ${BTRFS_MOUNT_OPTS}"
    echo -e "  Timezone / Locale:          ${TIMEZONE} / ${LOCALE}"
    echo -e "  Target Hostname:            ${HOSTNAME}"
    echo -e "  Primary User:               ${USERNAME}"
    echo -e "  Window Manager:             ${CLR_BOLD}${WM}${CLR_RESET}"
    echo -e "  Terminal Emulator:          ${TERMINAL}"
    echo -e "  Display Manager:            ${DISPLAY_MANAGER}"
    echo -e "  Graphics Drivers:           Intel UHD 620 (i915) + AMD R5 M330 (amdgpu SI)"
    echo -e "  PRIME Offloading:           Enabled (/usr/local/bin/prime-run)"
    echo -e "  Thermal & Power:            TLP + thermald (tuned for i5-8250U)"
    echo -e "  ZRAM Allocation:            50% RAM (${ZRAM_ALGORITHM})"
    echo -e "================================================================================"
}

main() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run|-d)
                export DRY_RUN=1
                ;;
            --help|-h)
                echo "Usage: $0 [--dry-run|-d] [--help|-h]"
                echo "  --dry-run, -d : Perform a simulated dry-run validation without modifying disks or running chroot."
                echo "  --help, -h    : Show this help message."
                exit 0
                ;;
        esac
    done

    clear 2>/dev/null || true
    print_banner
    check_root
    check_uefi
    check_network
    show_summary

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "DRY-RUN mode enabled. Simulating execution without destructive disk actions."
        "${SCRIPT_DIR}/stage1_disk_base.sh"
        log_info "[DRY-RUN] Simulating Stage 2 in chroot environment..."
        python3 "${SCRIPT_DIR}/tests/test_archsetup.py"
        echo ""
        log_success "[DRY-RUN] Full simulation and validation completed successfully!"
        exit 0
    fi

    echo ""
    read -rp "Do you wish to start the installation? [y/N]: " PROCEED
    if [[ ! "${PROCEED}" =~ ^[Yy]$ ]]; then
        log_warn "Installation aborted by user."
        exit 0
    fi

    # --------------------------------------------------------------------------
    # Stage 1: Disks, Filesystems, Subvolumes & Pacstrap
    # --------------------------------------------------------------------------
    log_step "Executing Stage 1: Partitioning, Btrfs Setup & Pacstrap"
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
    echo -e "${CLR_BOLD}Hybrid Graphics Usage:${CLR_RESET}"
    echo -e "  - Standard desktop apps run automatically on Intel UHD 620."
    echo -e "  - Offload demanding games/3D apps to AMD Radeon R5 M330 via:"
    echo -e "      ${CLR_BOLD}prime-run <command>${CLR_RESET}   (e.g., prime-run vkcube or prime-run glxinfo -B)"
    echo -e ""
    echo -e "${CLR_BOLD}Btrfs Snapshot Management:${CLR_RESET}"
    echo -e "  - Snapper/btrfs snapshots taken in /.snapshots are automatically"
    echo -e "    picked up by ${CLR_BOLD}grub-btrfs${CLR_RESET} and displayed in the GRUB boot menu."
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"
}

main "$@"
