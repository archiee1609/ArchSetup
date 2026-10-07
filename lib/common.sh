#!/usr/bin/env bash
# ==============================================================================
# Common Library for Arch Linux Deployment Scripts
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_INFO="\033[1;34m"     # Bold Blue
CLR_WARN="\033[1;33m"     # Bold Yellow
CLR_ERROR="\033[1;31m"    # Bold Red
CLR_SUCCESS="\033[1;32m"  # Bold Green
CLR_STEP="\033[1;36m"     # Bold Cyan
CLR_BOLD="\033[1m"        # Bold
CLR_DIM="\033[2m"         # Dim

log_info() {
    printf "${CLR_INFO}[INFO]${CLR_RESET} %s\n" "$*"
}

log_warn() {
    printf "${CLR_WARN}[WARN]${CLR_RESET} %s\n" "$*"
}

log_error() {
    printf "${CLR_ERROR}[ERROR]${CLR_RESET} %s\n" "$*" >&2
}

log_success() {
    printf "${CLR_SUCCESS}[SUCCESS]${CLR_RESET} %s\n" "$*"
}

log_step() {
    printf "\n${CLR_STEP}==>${CLR_RESET} ${CLR_BOLD}%s${CLR_RESET}\n" "$*"
}

DRY_RUN="${DRY_RUN:-0}"

check_root() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Skipping root privilege check."
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be executed with administrative privileges (root)."
        exit 1
    fi
}

check_uefi() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Skipping UEFI check."
        return 0
    fi
    log_info "Verifying UEFI boot mode..."
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        log_error "System is not booted in UEFI mode. Please boot the Arch ISO with UEFI enabled in BIOS."
        exit 1
    fi
    log_success "UEFI boot environment verified."
}

check_network() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Skipping network connectivity check."
        return 0
    fi
    log_info "Checking network connectivity..."
    if ! ping -c 1 -W 3 archlinux.org > /dev/null 2>&1 && ! ping -c 1 -W 3 1.1.1.1 > /dev/null 2>&1; then
        log_error "Network connection unavailable. Please connect to the internet (e.g. iwctl or ethernet) and re-run."
        exit 1
    fi
    log_success "Internet connectivity active."
}

verify_block_device() {
    local dev="$1"
    if [[ ! -b "$dev" ]]; then
        log_error "Block device '${dev}' does not exist or is not a block device."
        log_error "Available block devices:"
        lsblk -d -e 7,11 -o NAME,SIZE,MODEL,TRAN,ROTA,TYPE || true
        exit 1
    fi
}

get_partition_name() {
    local disk="$1"
    local part_num="$2"
    # Append 'p' if disk ends with a digit (e.g. /dev/nvme0n1 -> /dev/nvme0n1p1)
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

detect_sata_disks() {
    # Detect up to 2 SATA SSD block devices
    local disks
    disks=$(lsblk -d -n -o NAME,TRAN,ROTA | awk '$2=="sata" && $3=="0" {print "/dev/"$1}')
    local count
    count=$(echo "$disks" | grep -c "^/dev/" || true)
    if [[ "$count" -ge 2 ]]; then
        local d1 d2
        d1=$(echo "$disks" | sed -n '1p')
        d2=$(echo "$disks" | sed -n '2p')
        echo "$d1 $d2"
    else
        echo ""
    fi
}
