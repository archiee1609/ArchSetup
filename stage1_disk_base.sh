#!/usr/bin/env bash
# ==============================================================================
# Stage 1: Disk Partitioning, Btrfs Setup, Pacstrap & Chroot Preparation
# Hardware-Aware & Adaptive (Supports Single-Disk & Multi-Disk Pools)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library and user configuration
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
else
    log_warn "config.env not found in script directory. Using internal defaults."
fi

# Load pre-detected hardware profile if present, or run detection
if [[ -f "${SCRIPT_DIR}/hardware.env" ]]; then
    # shellcheck source=hardware.env
    source "${SCRIPT_DIR}/hardware.env"
elif [[ "${AUTO_DETECT_HARDWARE:-true}" == "true" ]]; then
    detect_hardware
    apply_hardware_profile
fi

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
check_root
check_uefi
check_network

log_step "Storage Architecture Verification"

# Auto-detect fallback if disks are not provided or don't exist
if [[ "${DRY_RUN:-0}" != "1" ]]; then
    if [[ -z "${DISK1:-}" || ! -b "${DISK1:-}" ]]; then
        log_warn "Configured primary drive (${DISK1:-unset}) not found or invalid."
        log_info "Attempting automatic discovery of storage drives..."
        detect_disks
        apply_hardware_profile
        log_info "Auto-detected primary drive:   ${DISK1}"
        if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
            log_info "Auto-detected secondary drive: ${DISK2}"
        fi
    fi

    # Verify primary block device
    verify_block_device "${DISK1}"

    # Verify secondary block device only if in multi-device mode
    if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
        if [[ "${DISK1}" == "${DISK2}" ]]; then
            log_error "DISK1 and DISK2 cannot point to the same physical drive (${DISK1}). Switching to single-disk mode."
            DISK2=""
            BTRFS_MODE="single_disk"
        else
            verify_block_device "${DISK2}"
        fi
    fi
fi

# Partition device paths
PART_EFI="$(get_partition_name "${DISK1}" 1)"
PART_ROOT="$(get_partition_name "${DISK1}" 2)"
PART_DRIVE2=""
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    PART_DRIVE2="$(get_partition_name "${DISK2}" 1)"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY-RUN] Simulating Stage 1 partition calculation and command generation:"
    log_info "[DRY-RUN] Primary Disk:      ${DISK1} -> EFI: ${PART_EFI}, Root: ${PART_ROOT}"
    log_info "[DRY-RUN] Partitioning Command 1: sgdisk -n 1:0:+1G -t 1:ef00 -c 1:\"EFI-SYSTEM\" ${DISK1}"
    log_info "[DRY-RUN] Partitioning Command 2: sgdisk -n 2:0:0 -t 2:8300 -c 2:\"ARCH-BTRFS-ROOT\" ${DISK1}"
    if [[ -n "${PART_DRIVE2}" && "${BTRFS_MODE}" != "single_disk" ]]; then
        log_info "[DRY-RUN] Secondary Disk:    ${DISK2} -> Span: ${PART_DRIVE2}"
        log_info "[DRY-RUN] Partitioning Command 3: sgdisk -n 1:0:0 -t 1:8300 -c 1:\"ARCH-BTRFS-DRIVE2\" ${DISK2}"
    fi
    log_info "[DRY-RUN] EFI Format Command:    mkfs.vfat -F32 -n \"EFI\" ${PART_EFI}"
    if [[ "${BTRFS_MODE}" == "raid0" && -n "${PART_DRIVE2}" ]]; then
        log_info "[DRY-RUN] Btrfs Pool Command:    mkfs.btrfs -f -L \"ARCH_ROOT\" -d raid0 -m raid1 ${PART_ROOT} ${PART_DRIVE2}"
    elif [[ "${BTRFS_MODE}" == "single" && -n "${PART_DRIVE2}" ]]; then
        log_info "[DRY-RUN] Btrfs Pool Command:    mkfs.btrfs -f -L \"ARCH_ROOT\" -d single -m single ${PART_ROOT} ${PART_DRIVE2}"
    elif [[ "${BTRFS_MODE}" == "separate" && -n "${PART_DRIVE2}" ]]; then
        log_info "[DRY-RUN] Btrfs Pool Command 1:  mkfs.btrfs -f -L \"ARCH_ROOT\" ${PART_ROOT}"
        log_info "[DRY-RUN] Btrfs Pool Command 2:  mkfs.btrfs -f -L \"ARCH_DATA\" ${PART_DRIVE2}"
    else
        log_info "[DRY-RUN] Btrfs Root Command:    mkfs.btrfs -f -L \"ARCH_ROOT\" ${PART_ROOT}"
    fi
    log_info "[DRY-RUN] Mount Options:         ${BTRFS_MOUNT_OPTS}"
    log_info "[DRY-RUN] Subvolumes Planned:    @ -> /, @home -> /home, @snapshots -> /.snapshots, @var_log -> /var/log, @pkg -> /var/cache/pacman/pkg"
    log_success "[DRY-RUN] Stage 1 simulation validated successfully."
    exit 0
fi

# ------------------------------------------------------------------------------
# User Safety Confirmation Prompt
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_ERROR}======================================================================"
echo -e "                   DANGER: DISK PARTITIONING & FORMATTING             "
echo -e "======================================================================${CLR_RESET}"
echo -e "Target Drive 1 (Primary):    ${CLR_BOLD}${DISK1}${CLR_RESET} [$(lsblk -d -n -o MODEL,SIZE "${DISK1}" 2>/dev/null | xargs)]"
echo -e "  - Partition 1: 1 GiB EFI System Partition (vfat -> /boot)"
echo -e "  - Partition 2: Remainder Btrfs root subvolumes"
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    echo -e "Target Drive 2 (Secondary):  ${CLR_BOLD}${DISK2}${CLR_RESET} [$(lsblk -d -n -o MODEL,SIZE "${DISK2}" 2>/dev/null | xargs)]"
    echo -e "  - Btrfs Mode:               ${CLR_BOLD}${BTRFS_MODE}${CLR_RESET}"
else
    echo -e "Storage Architecture:       ${CLR_BOLD}Single-Disk Btrfs Layout${CLR_RESET}"
fi
echo -e "Subvolume Structure:        @ -> /"
echo -e "                            @home -> /home"
echo -e "                            @snapshots -> /.snapshots"
echo -e "                            @var_log -> /var/log"
echo -e "                            @pkg -> /var/cache/pacman/pkg"
echo -e "Mount Options:              ${BTRFS_MOUNT_OPTS}"
echo -e "${CLR_ERROR}----------------------------------------------------------------------"
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    echo -e "ALL DATA ON ${DISK1} AND ${DISK2} WILL BE PERMANENTLY DESTROYED!${CLR_RESET}"
else
    echo -e "ALL DATA ON ${DISK1} WILL BE PERMANENTLY DESTROYED!${CLR_RESET}"
fi
echo -e "${CLR_ERROR}======================================================================${CLR_RESET}"
echo ""

read -rp "Are you absolutely sure you wish to proceed? Type 'YES' to format: " CONFIRMATION
if [[ "${CONFIRMATION}" != "YES" ]]; then
    log_warn "Installation aborted by user. No disk modifications were made."
    exit 0
fi

# ------------------------------------------------------------------------------
# Disk Cleanup & Partitioning
# ------------------------------------------------------------------------------
log_step "Unmounting existing partitions and wiping disk signatures"

# Safely unmount any active mounts under /mnt
if mountpoint -q /mnt; then
    log_info "Unmounting existing mounts under /mnt..."
    umount -R /mnt 2>/dev/null || true
fi
swapoff -a 2>/dev/null || true

# Erase partition tables and wipe filesystem superblocks on primary disk
log_info "Wiping partition tables on ${DISK1}..."
wipefs --all --force "${DISK1}" > /dev/null 2>&1 || true
sgdisk --zap-all "${DISK1}" > /dev/null 2>&1

# Erase secondary disk only if in multi-device mode
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    log_info "Wiping partition tables on ${DISK2}..."
    wipefs --all --force "${DISK2}" > /dev/null 2>&1 || true
    sgdisk --zap-all "${DISK2}" > /dev/null 2>&1
fi

sleep 1
partprobe "${DISK1}" 2>/dev/null || true
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    partprobe "${DISK2}" 2>/dev/null || true
fi

log_step "Partitioning Drives"

# Drive 1 Partitioning:
# 1. 1GB EFI System Partition (type ef00)
# 2. Remainder Btrfs root filesystem (type 8300)
log_info "Partitioning ${DISK1} (1GB EFI + Btrfs)..."
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI-SYSTEM" "${DISK1}"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ARCH-BTRFS-ROOT" "${DISK1}"

# Drive 2 Partitioning (if multi-device mode):
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    log_info "Partitioning ${DISK2} (Full disk Btrfs)..."
    sgdisk -n 1:0:0 -t 1:8300 -c 1:"ARCH-BTRFS-DRIVE2" "${DISK2}"
fi

sleep 2
partprobe "${DISK1}" 2>/dev/null || true
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    partprobe "${DISK2}" 2>/dev/null || true
fi
sleep 1

# Resolve partition paths
PART_EFI="$(get_partition_name "${DISK1}" 1)"
PART_ROOT="$(get_partition_name "${DISK1}" 2)"
if [[ -n "${DISK2:-}" && "${BTRFS_MODE:-}" != "single_disk" ]]; then
    PART_DRIVE2="$(get_partition_name "${DISK2}" 1)"
fi

log_info "Resolved Partition Devices:"
log_info "  EFI Partition:      ${PART_EFI}"
log_info "  Root Btrfs Device:  ${PART_ROOT}"
if [[ -n "${PART_DRIVE2}" ]]; then
    log_info "  Drive 2 Device:     ${PART_DRIVE2}"
fi

# ------------------------------------------------------------------------------
# Filesystem Creation & Btrfs Subvolumes
# ------------------------------------------------------------------------------
log_step "Formatting EFI System Partition"
mkfs.vfat -F32 -n "EFI" "${PART_EFI}"
log_success "EFI partition formatted (FAT32)."

log_step "Creating Btrfs Filesystem (Mode: ${BTRFS_MODE})"

case "${BTRFS_MODE}" in
    single_disk)
        log_info "Creating single-disk Btrfs filesystem on ${PART_ROOT}..."
        mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
        ;;
    raid0)
        log_info "Creating spanned Btrfs RAID0 pool across ${PART_ROOT} and ${PART_DRIVE2}..."
        mkfs.btrfs -f -L "ARCH_ROOT" -d raid0 -m raid1 "${PART_ROOT}" "${PART_DRIVE2}"
        ;;
    single)
        log_info "Creating spanned Btrfs single pool across ${PART_ROOT} and ${PART_DRIVE2}..."
        mkfs.btrfs -f -L "ARCH_ROOT" -d single -m single "${PART_ROOT}" "${PART_DRIVE2}"
        ;;
    separate)
        log_info "Creating primary Btrfs filesystem on ${PART_ROOT}..."
        mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
        log_info "Creating secondary Btrfs filesystem on ${PART_DRIVE2}..."
        mkfs.btrfs -f -L "ARCH_DATA" "${PART_DRIVE2}"
        ;;
    *)
        log_warn "Unknown or unhandled BTRFS_MODE: '${BTRFS_MODE}'. Falling back to single-disk mode on ${PART_ROOT}."
        mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
        ;;
esac

log_step "Creating Btrfs Subvolume Structure"

# Mount root pool temporarily to create subvolumes
mkdir -p /mnt
mount -t btrfs "${PART_ROOT}" /mnt

log_info "Creating subvolumes: @, @home, @snapshots, @var_log, @pkg..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@pkg

umount /mnt
log_success "Subvolumes created."

# ------------------------------------------------------------------------------
# Mounting Subvolumes and Target Hierarchy
# ------------------------------------------------------------------------------
log_step "Mounting Subvolumes with Performance Options (${BTRFS_MOUNT_OPTS})"

# Mount root subvolume (@)
mount -o "${BTRFS_MOUNT_OPTS},subvol=@" "${PART_ROOT}" /mnt

# Create directory tree
mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache/pacman/pkg}

# Mount nested subvolumes
mount -o "${BTRFS_MOUNT_OPTS},subvol=@home" "${PART_ROOT}" /mnt/home
mount -o "${BTRFS_MOUNT_OPTS},subvol=@snapshots" "${PART_ROOT}" /mnt/.snapshots
mount -o "${BTRFS_MOUNT_OPTS},subvol=@var_log" "${PART_ROOT}" /mnt/var/log
mount -o "${BTRFS_MOUNT_OPTS},subvol=@pkg" "${PART_ROOT}" /mnt/var/cache/pacman/pkg

# Mount EFI System Partition directly at /boot
mount "${PART_EFI}" /mnt/boot

# Mount secondary standalone drive if requested
if [[ "${BTRFS_MODE}" == "separate" && -n "${PART_DRIVE2}" ]]; then
    mkdir -p "/mnt${SECONDARY_MOUNT}"
    mount -o "${BTRFS_MOUNT_OPTS}" "${PART_DRIVE2}" "/mnt${SECONDARY_MOUNT}"
    log_info "Secondary drive mounted at /mnt${SECONDARY_MOUNT}."
fi

log_success "All filesystems and subvolumes mounted successfully."

# ------------------------------------------------------------------------------
# Base System Pacstrap
# ------------------------------------------------------------------------------
log_step "Synchronizing Pacman Keys & Mirrors"
pacman -Sy --noconfirm archlinux-keyring || true

log_step "Bootstrapping Base System via Pacstrap"

BASE_PACKAGES=(
    base
    base-devel
    linux
    linux-headers
    linux-firmware
    btrfs-progs
    grub
    efibootmgr
    grub-btrfs
    inotify-tools
    networkmanager
    wireless_tools
    wpa_supplicant
    sudo
    git
    curl
    wget
    nano
    vim
    bash
    bash-completion
    fish
    zram-generator
    pciutils
    usbutils
)

# Dynamically add CPU microcode package based on recognized CPU architecture
UCODE_PKG="${CPU_UCODE_PACKAGE:-intel-ucode}"
if [[ -n "$UCODE_PKG" ]]; then
    BASE_PACKAGES+=("$UCODE_PKG")
    log_info "Including detected CPU microcode package: ${UCODE_PKG}"
fi

# If virtual machine detected, include appropriate guest agent
if [[ "${IS_VM:-0}" -eq 1 ]]; then
    case "${VIRT_TYPE:-none}" in
        oracle)
            BASE_PACKAGES+=(virtualbox-guest-utils)
            log_info "Including VirtualBox guest utilities"
            ;;
        vmware)
            BASE_PACKAGES+=(open-vm-tools)
            log_info "Including VMware open-vm-tools"
            ;;
        kvm|qemu)
            BASE_PACKAGES+=(qemu-guest-agent)
            log_info "Including QEMU guest agent"
            ;;
    esac
fi

log_info "Installing core packages to /mnt (this may take several minutes)..."
pacstrap -K /mnt "${BASE_PACKAGES[@]}"

log_success "Base system installed successfully."

# ------------------------------------------------------------------------------
# FSTAB Generation
# ------------------------------------------------------------------------------
log_step "Generating /etc/fstab"
genfstab -U /mnt > /mnt/etc/fstab

log_info "Generated /etc/fstab content:"
cat /mnt/etc/fstab

# ------------------------------------------------------------------------------
# Chroot Environment Preparation
# ------------------------------------------------------------------------------
log_step "Deploying Stage 2 installer scripts and configs into chroot"

CHROOT_INSTALLER_DIR="/mnt/opt/arch_installer"
mkdir -p "${CHROOT_INSTALLER_DIR}"

cp -r "${SCRIPT_DIR}/config.env" "${CHROOT_INSTALLER_DIR}/"
cp -r "${SCRIPT_DIR}/lib" "${CHROOT_INSTALLER_DIR}/"
cp -r "${SCRIPT_DIR}/configs" "${CHROOT_INSTALLER_DIR}/"
if [[ -f "${SCRIPT_DIR}/hardware.env" ]]; then
    cp "${SCRIPT_DIR}/hardware.env" "${CHROOT_INSTALLER_DIR}/"
fi
cp "${SCRIPT_DIR}/stage2_chroot.sh" "${CHROOT_INSTALLER_DIR}/"
chmod +x "${CHROOT_INSTALLER_DIR}/stage2_chroot.sh"

log_success "Stage 1 completed successfully."
log_info "To execute Stage 2 inside chroot, execute:"
log_info "  arch-chroot /mnt /opt/arch_installer/stage2_chroot.sh"
