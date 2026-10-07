#!/usr/bin/env bash
# ==============================================================================
# Stage 1: Disk Partitioning, Btrfs Setup, Pacstrap & Chroot Preparation
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

if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck source=config.env
    source "${SCRIPT_DIR}/config.env"
else
    log_warn "config.env not found in script directory. Using internal defaults."
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
    if [[ ! -b "${DISK1}" || ! -b "${DISK2}" ]]; then
        log_warn "Configured drives (${DISK1}, ${DISK2}) not found or invalid."
        log_info "Attempting automatic discovery of SATA SSDs..."
        DETECTED_DISKS="$(detect_sata_disks)"
        if [[ -n "$DETECTED_DISKS" ]]; then
            DISK1=$(echo "$DETECTED_DISKS" | awk '{print $1}')
            DISK2=$(echo "$DETECTED_DISKS" | awk '{print $2}')
            log_info "Auto-detected primary drive:   ${DISK1}"
            log_info "Auto-detected secondary drive: ${DISK2}"
        else
            log_error "Failed to automatically identify dual SATA SSD drives."
            log_error "Please manually edit config.env and specify DISK1 and DISK2."
            exit 1
        fi
    fi

    # Verify block devices
    verify_block_device "${DISK1}"
    verify_block_device "${DISK2}"
fi

if [[ "${DISK1}" == "${DISK2}" ]]; then
    log_error "DISK1 and DISK2 cannot point to the same physical drive (${DISK1})."
    exit 1
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY-RUN] Simulating Stage 1 partition calculation and command generation:"
    PART_EFI="$(get_partition_name "${DISK1}" 1)"
    PART_ROOT="$(get_partition_name "${DISK1}" 2)"
    PART_DRIVE2="$(get_partition_name "${DISK2}" 1)"
    log_info "[DRY-RUN] Primary Disk:      ${DISK1} -> EFI: ${PART_EFI}, Root: ${PART_ROOT}"
    log_info "[DRY-RUN] Secondary Disk:    ${DISK2} -> Span: ${PART_DRIVE2}"
    log_info "[DRY-RUN] Partitioning Command 1: sgdisk -n 1:0:+1G -t 1:ef00 -c 1:\"EFI-SYSTEM\" ${DISK1}"
    log_info "[DRY-RUN] Partitioning Command 2: sgdisk -n 2:0:0 -t 2:8300 -c 2:\"ARCH-BTRFS-ROOT\" ${DISK1}"
    log_info "[DRY-RUN] Partitioning Command 3: sgdisk -n 1:0:0 -t 1:8300 -c 1:\"ARCH-BTRFS-DRIVE2\" ${DISK2}"
    log_info "[DRY-RUN] EFI Format Command:    mkfs.vfat -F32 -n \"EFI\" ${PART_EFI}"
    if [[ "${BTRFS_MODE}" == "raid0" ]]; then
        log_info "[DRY-RUN] Btrfs Pool Command:    mkfs.btrfs -f -L \"ARCH_ROOT\" -d raid0 -m raid1 ${PART_ROOT} ${PART_DRIVE2}"
    elif [[ "${BTRFS_MODE}" == "single" ]]; then
        log_info "[DRY-RUN] Btrfs Pool Command:    mkfs.btrfs -f -L \"ARCH_ROOT\" -d single -m single ${PART_ROOT} ${PART_DRIVE2}"
    else
        log_info "[DRY-RUN] Btrfs Pool Command 1:  mkfs.btrfs -f -L \"ARCH_ROOT\" ${PART_ROOT}"
        log_info "[DRY-RUN] Btrfs Pool Command 2:  mkfs.btrfs -f -L \"ARCH_DATA\" ${PART_DRIVE2}"
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
echo -e "Target Drive 1 (Primary):    ${CLR_BOLD}${DISK1}${CLR_RESET} [$(lsblk -d -n -o MODEL,SIZE "${DISK1}" | xargs)]"
echo -e "  - Partition 1: 1 GiB EFI System Partition (vfat -> /boot)"
echo -e "  - Partition 2: Remainder Btrfs root subvolumes"
echo -e "Target Drive 2 (Secondary):  ${CLR_BOLD}${DISK2}${CLR_RESET} [$(lsblk -d -n -o MODEL,SIZE "${DISK2}" | xargs)]"
echo -e "  - Btrfs Mode:               ${CLR_BOLD}${BTRFS_MODE}${CLR_RESET}"
echo -e "Subvolume Structure:        @ -> /"
echo -e "                            @home -> /home"
echo -e "                            @snapshots -> /.snapshots"
echo -e "                            @var_log -> /var/log"
echo -e "                            @pkg -> /var/cache/pacman/pkg"
echo -e "Mount Options:              ${BTRFS_MOUNT_OPTS}"
echo -e "${CLR_ERROR}----------------------------------------------------------------------"
echo -e "ALL DATA ON ${DISK1} AND ${DISK2} WILL BE PERMANENTLY DESTROYED!${CLR_RESET}"
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

# Erase partition tables and wipe filesystem superblocks
log_info "Wiping partition tables on ${DISK1}..."
wipefs --all --force "${DISK1}" > /dev/null 2>&1 || true
sgdisk --zap-all "${DISK1}" > /dev/null 2>&1

log_info "Wiping partition tables on ${DISK2}..."
wipefs --all --force "${DISK2}" > /dev/null 2>&1 || true
sgdisk --zap-all "${DISK2}" > /dev/null 2>&1

sleep 1
partprobe "${DISK1}" 2>/dev/null || true
partprobe "${DISK2}" 2>/dev/null || true

log_step "Partitioning Drives"

# Drive 1 Partitioning:
# 1. 1GB EFI System Partition (type ef00)
# 2. Remainder Btrfs root filesystem (type 8300)
log_info "Partitioning ${DISK1} (1GB EFI + Btrfs)..."
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI-SYSTEM" "${DISK1}"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ARCH-BTRFS-ROOT" "${DISK1}"

# Drive 2 Partitioning:
# Full disk partition for secondary / spanned Btrfs (type 8300)
log_info "Partitioning ${DISK2} (Full disk Btrfs)..."
sgdisk -n 1:0:0 -t 1:8300 -c 1:"ARCH-BTRFS-DRIVE2" "${DISK2}"

sleep 2
partprobe "${DISK1}" 2>/dev/null || true
partprobe "${DISK2}" 2>/dev/null || true
sleep 1

# Resolve partition paths
PART_EFI="$(get_partition_name "${DISK1}" 1)"
PART_ROOT="$(get_partition_name "${DISK1}" 2)"
PART_DRIVE2="$(get_partition_name "${DISK2}" 1)"

log_info "Resolved Partition Devices:"
log_info "  EFI Partition:      ${PART_EFI}"
log_info "  Root Btrfs Device:  ${PART_ROOT}"
log_info "  Drive 2 Device:     ${PART_DRIVE2}"

# ------------------------------------------------------------------------------
# Filesystem Creation & Btrfs Subvolumes
# ------------------------------------------------------------------------------
log_step "Formatting EFI System Partition"
mkfs.vfat -F32 -n "EFI" "${PART_EFI}"
log_success "EFI partition formatted (FAT32)."

log_step "Creating Btrfs Filesystem (Mode: ${BTRFS_MODE})"

case "${BTRFS_MODE}" in
    raid0)
        # Multi-device RAID0 (Striped data across both SSDs for double speed, RAID1 metadata)
        log_info "Creating spanned Btrfs RAID0 pool across ${PART_ROOT} and ${PART_DRIVE2}..."
        mkfs.btrfs -f -L "ARCH_ROOT" -d raid0 -m raid1 "${PART_ROOT}" "${PART_DRIVE2}"
        ;;
    single)
        # Linear concatenation across both SSDs
        log_info "Creating spanned Btrfs single pool across ${PART_ROOT} and ${PART_DRIVE2}..."
        mkfs.btrfs -f -L "ARCH_ROOT" -d single -m single "${PART_ROOT}" "${PART_DRIVE2}"
        ;;
    separate)
        # Standalone filesystems
        log_info "Creating primary Btrfs filesystem on ${PART_ROOT}..."
        mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
        log_info "Creating secondary Btrfs filesystem on ${PART_DRIVE2}..."
        mkfs.btrfs -f -L "ARCH_DATA" "${PART_DRIVE2}"
        ;;
    *)
        log_error "Unknown BTRFS_MODE: '${BTRFS_MODE}'. Choose 'raid0', 'single', or 'separate'."
        exit 1
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
if [[ "${BTRFS_MODE}" == "separate" ]]; then
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
    intel-ucode
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
    zram-generator
    pciutils
    usbutils
)

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
cp "${SCRIPT_DIR}/stage2_chroot.sh" "${CHROOT_INSTALLER_DIR}/"
chmod +x "${CHROOT_INSTALLER_DIR}/stage2_chroot.sh"

log_success "Stage 1 completed successfully."
log_info "To execute Stage 2 inside chroot, execute:"
log_info "  arch-chroot /mnt /opt/arch_installer/stage2_chroot.sh"
