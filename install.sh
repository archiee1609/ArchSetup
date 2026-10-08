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
        Adaptive Hardware-Aware Installer & Tiling Environment
================================================================================
EOF
}

show_summary() {
    echo -e "${CLR_STEP}Installation & Target Configuration Summary:${CLR_RESET}"
    echo -e "  Primary Storage (DISK1):    ${CLR_BOLD}${DISK1}${CLR_RESET}"
    if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
        echo -e "  Secondary Storage (DISK2):  ${CLR_BOLD}${DISK2}${CLR_RESET}"
        echo -e "  Btrfs Pool Strategy:        ${CLR_BOLD}${BTRFS_MODE}${CLR_RESET}"
    else
        echo -e "  Secondary Storage:          ${CLR_DIM}None (Single-Disk Layout)${CLR_RESET}"
        echo -e "  Btrfs Storage Mode:         ${CLR_BOLD}single_disk${CLR_RESET}"
    fi
    echo -e "  Mount Options:              ${BTRFS_MOUNT_OPTS}"
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
    echo -e "  Timezone / Locale:          ${TIMEZONE} / ${LOCALE}"
    echo -e "  Target Hostname:            ${HOSTNAME}"
    echo -e "  Primary User:               ${USERNAME}"
    echo -e "  Window Manager:             ${CLR_BOLD}${WM}${CLR_RESET}"
    echo -e "  Terminal Emulator:          ${TERMINAL}"
    echo -e "  Display Manager:            ${DISPLAY_MANAGER}"
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

    # Automatically probe hardware specifications if enabled
    if [[ "${AUTO_DETECT_HARDWARE:-true}" == "true" ]]; then
        log_step "Probing System Hardware Specifications"
        detect_hardware
        apply_hardware_profile
        print_hardware_report
        save_hardware_profile "${SCRIPT_DIR}/hardware.env"
    fi

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
    read -rp "Do you wish to start the installation with these specifications? [y/N]: " PROCEED
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
    if [[ "${PRIME_TYPE:-none}" != "none" ]]; then
        echo -e "${CLR_BOLD}PRIME Offload Usage (${PRIME_TYPE}):${CLR_RESET}"
        echo -e "  - Standard desktop apps run on primary display GPU."
        echo -e "  - Offload demanding games/3D apps to discrete GPU via:"
        echo -e "      ${CLR_BOLD}prime-run <command>${CLR_RESET}   (e.g., prime-run vkcube)"
        echo -e ""
    fi
    echo -e "${CLR_BOLD}Btrfs Snapshot Management:${CLR_RESET}"
    echo -e "  - Snapper/btrfs snapshots taken in /.snapshots are automatically"
    echo -e "    picked up by ${CLR_BOLD}grub-btrfs${CLR_RESET} and displayed in the GRUB boot menu."
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"
}

main "$@"
