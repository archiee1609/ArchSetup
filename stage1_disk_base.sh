#!/usr/bin/env bash
# ==============================================================================
# Stage 1: Disk Partitioning, Filesystem Setup, Pacstrap & Chroot Preparation
# Hardware-Aware & Adaptive (Supports Single-Disk & All-Disk Layouts,
# and multiple filesystems: Btrfs, ext4, XFS, F2FS)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture any environment / CLI variable overrides
_OVERRIDE_DISK_LAYOUT="${DISK_LAYOUT:-}"
_OVERRIDE_DISK1="${DISK1:-}"
_OVERRIDE_DISK2="${DISK2:-}"
_OVERRIDE_FILESYSTEM="${FILESYSTEM:-${FS_TYPE:-}}"
_OVERRIDE_BTRFS_MODE="${BTRFS_MODE:-}"
_OVERRIDE_DESKTOP_ENV="${DESKTOP_ENV:-${WM:-}}"
_OVERRIDE_DISPLAY_MANAGER="${DISPLAY_MANAGER:-}"

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

# Re-apply explicit environment overrides
[[ -n "$_OVERRIDE_DISK_LAYOUT" ]] && DISK_LAYOUT="$_OVERRIDE_DISK_LAYOUT"
[[ -n "$_OVERRIDE_DISK1" ]] && DISK1="$_OVERRIDE_DISK1"
[[ -n "$_OVERRIDE_DISK2" ]] && DISK2="$_OVERRIDE_DISK2"
[[ -n "$_OVERRIDE_FILESYSTEM" ]] && FILESYSTEM="$_OVERRIDE_FILESYSTEM"
[[ -n "$_OVERRIDE_BTRFS_MODE" ]] && BTRFS_MODE="$_OVERRIDE_BTRFS_MODE"
[[ -n "$_OVERRIDE_DESKTOP_ENV" ]] && DESKTOP_ENV="$_OVERRIDE_DESKTOP_ENV"
[[ -n "$_OVERRIDE_DISPLAY_MANAGER" ]] && DISPLAY_MANAGER="$_OVERRIDE_DISPLAY_MANAGER"

# Resolve core configuration variables
DISK_LAYOUT="${DISK_LAYOUT:-single}"
FILESYSTEM="${FILESYSTEM:-${FS_TYPE:-btrfs}}"
FS_TYPE="${FILESYSTEM}"
BTRFS_MODE="${BTRFS_MODE:-single_disk}"
SECONDARY_MOUNT="${SECONDARY_MOUNT:-/data}"

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
    fi

    # Verify primary block device
    verify_block_device "${DISK1}"

    # Verify secondary block device only if in all-disks mode
    if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
        if [[ "${DISK1}" == "${DISK2}" ]]; then
            log_error "DISK1 and DISK2 cannot point to the same physical drive (${DISK1}). Switching to single-disk mode."
            DISK2=""
            DISK_LAYOUT="single"
            BTRFS_MODE="single_disk"
        else
            verify_block_device "${DISK2}"
        fi
    else
        DISK2=""
        if [[ "${FILESYSTEM}" == "btrfs" ]]; then
            BTRFS_MODE="single_disk"
        fi
    fi
fi

# Partition device paths
PART_EFI="$(get_partition_name "${DISK1}" 1)"
PART_ROOT="$(get_partition_name "${DISK1}" 2)"
PART_DRIVE2=""
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    PART_DRIVE2="$(get_partition_name "${DISK2}" 1)"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY-RUN] Simulating Stage 1 partition calculation and command generation:"
    log_info "[DRY-RUN] Storage Target Mode: ${DISK_LAYOUT}"
    log_info "[DRY-RUN] Filesystem Scheme:   ${FILESYSTEM}"
    log_info "[DRY-RUN] Primary Disk:        ${DISK1} -> EFI: ${PART_EFI}, Root: ${PART_ROOT}"
    log_info "[DRY-RUN] Partitioning Cmd 1:  sgdisk -n 1:0:+1G -t 1:ef00 -c 1:\"EFI-SYSTEM\" ${DISK1}"
    log_info "[DRY-RUN] Partitioning Cmd 2:  sgdisk -n 2:0:0 -t 2:8300 -c 2:\"ARCH-ROOT\" ${DISK1}"
    if [[ "${DISK_LAYOUT}" == "all" && -n "${PART_DRIVE2}" ]]; then
        log_info "[DRY-RUN] Secondary Disk:      ${DISK2} -> Data/Span: ${PART_DRIVE2}"
        log_info "[DRY-RUN] Partitioning Cmd 3:  sgdisk -n 1:0:0 -t 1:8300 -c 1:\"ARCH-DATA\" ${DISK2}"
    fi
    log_info "[DRY-RUN] EFI Format Command:  mkfs.vfat -F32 -n \"EFI\" ${PART_EFI}"
    
    case "${FILESYSTEM}" in
        btrfs)
            if [[ "${BTRFS_MODE}" == "raid0" && -n "${PART_DRIVE2}" ]]; then
                log_info "[DRY-RUN] Btrfs Pool Command:  mkfs.btrfs -f -L \"ARCH_ROOT\" -d raid0 -m raid1 ${PART_ROOT} ${PART_DRIVE2}"
            elif [[ "${BTRFS_MODE}" == "single" && -n "${PART_DRIVE2}" ]]; then
                log_info "[DRY-RUN] Btrfs Pool Command:  mkfs.btrfs -f -L \"ARCH_ROOT\" -d single -m single ${PART_ROOT} ${PART_DRIVE2}"
            elif [[ "${BTRFS_MODE}" == "separate" && -n "${PART_DRIVE2}" ]]; then
                log_info "[DRY-RUN] Btrfs Command 1:     mkfs.btrfs -f -L \"ARCH_ROOT\" ${PART_ROOT}"
                log_info "[DRY-RUN] Btrfs Command 2:     mkfs.btrfs -f -L \"ARCH_DATA\" ${PART_DRIVE2}"
            else
                log_info "[DRY-RUN] Btrfs Root Command:  mkfs.btrfs -f -L \"ARCH_ROOT\" ${PART_ROOT}"
            fi
            log_info "[DRY-RUN] Mount Options:       ${BTRFS_MOUNT_OPTS}"
            log_info "[DRY-RUN] Subvolumes Planned:  @ -> /, @home -> /home, @snapshots -> /.snapshots, @var_log -> /var/log, @pkg -> /var/cache/pacman/pkg"
            ;;
        ext4)
            log_info "[DRY-RUN] ext4 Root Command:   mkfs.ext4 -F -L \"ARCH_ROOT\" ${PART_ROOT}"
            if [[ -n "${PART_DRIVE2}" ]]; then
                log_info "[DRY-RUN] ext4 Data Command:   mkfs.ext4 -F -L \"ARCH_DATA\" ${PART_DRIVE2}"
                log_info "[DRY-RUN] Mounts Planned:      ${PART_ROOT} -> /, ${PART_EFI} -> /boot, ${PART_DRIVE2} -> ${SECONDARY_MOUNT}"
            else
                log_info "[DRY-RUN] Mounts Planned:      ${PART_ROOT} -> /, ${PART_EFI} -> /boot"
            fi
            log_info "[DRY-RUN] Mount Options:       ${EXT4_MOUNT_OPTS:-noatime,errors=remount-ro}"
            ;;
        xfs)
            log_info "[DRY-RUN] XFS Root Command:    mkfs.xfs -f -L \"ARCH_ROOT\" ${PART_ROOT}"
            if [[ -n "${PART_DRIVE2}" ]]; then
                log_info "[DRY-RUN] XFS Data Command:    mkfs.xfs -f -L \"ARCH_DATA\" ${PART_DRIVE2}"
                log_info "[DRY-RUN] Mounts Planned:      ${PART_ROOT} -> /, ${PART_EFI} -> /boot, ${PART_DRIVE2} -> ${SECONDARY_MOUNT}"
            else
                log_info "[DRY-RUN] Mounts Planned:      ${PART_ROOT} -> /, ${PART_EFI} -> /boot"
            fi
            log_info "[DRY-RUN] Mount Options:       ${XFS_MOUNT_OPTS:-noatime}"
            ;;
        f2fs)
            log_info "[DRY-RUN] F2FS Root Command:   mkfs.f2fs -f -l \"ARCH_ROOT\" ${PART_ROOT}"
            if [[ -n "${PART_DRIVE2}" ]]; then
                log_info "[DRY-RUN] F2FS Data Command:   mkfs.f2fs -f -l \"ARCH_DATA\" ${PART_DRIVE2}"
                log_info "[DRY-RUN] Mounts Planned:      ${PART_ROOT} -> /, ${PART_EFI} -> /boot, ${PART_DRIVE2} -> ${SECONDARY_MOUNT}"
            else
                log_info "[DRY-RUN] Mounts Planned:      ${PART_ROOT} -> /, ${PART_EFI} -> /boot"
            fi
            log_info "[DRY-RUN] Mount Options:       ${F2FS_MOUNT_OPTS:-noatime}"
            ;;
    esac

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
echo -e "Target Storage Mode:         ${CLR_BOLD}${DISK_LAYOUT}${CLR_RESET} ($([[ "${DISK_LAYOUT}" == "all" ]] && echo "Partition all detected drives" || echo "Single target drive only"))"
echo -e "Target Drive 1 (Primary):    ${CLR_BOLD}${DISK1}${CLR_RESET} [$(lsblk -d -n -o MODEL,SIZE "${DISK1}" 2>/dev/null | xargs)]"
echo -e "  - Partition 1: 1 GiB EFI System Partition (vfat -> /boot)"
echo -e "  - Partition 2: Remainder ${FILESYSTEM} root partition"
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    echo -e "Target Drive 2 (Secondary):  ${CLR_BOLD}${DISK2}${CLR_RESET} [$(lsblk -d -n -o MODEL,SIZE "${DISK2}" 2>/dev/null | xargs)]"
    if [[ "${FILESYSTEM}" == "btrfs" ]]; then
        echo -e "  - Btrfs Mode:               ${CLR_BOLD}${BTRFS_MODE}${CLR_RESET}"
    else
        echo -e "  - Secondary Mount:          ${CLR_BOLD}${SECONDARY_MOUNT}${CLR_RESET}"
    fi
fi
echo -e "Selected Filesystem Scheme:  ${CLR_BOLD}${FILESYSTEM}${CLR_RESET}"
if [[ "${FILESYSTEM}" == "btrfs" ]]; then
    echo -e "Subvolume Structure:        @ -> /"
    echo -e "                            @home -> /home"
    echo -e "                            @snapshots -> /.snapshots"
    echo -e "                            @var_log -> /var/log"
    echo -e "                            @pkg -> /var/cache/pacman/pkg"
    echo -e "Mount Options:              ${BTRFS_MOUNT_OPTS}"
fi
echo -e "${CLR_ERROR}----------------------------------------------------------------------"
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    echo -e "ALL DATA ON ${DISK1} AND ${DISK2} WILL BE PERMANENTLY DESTROYED!${CLR_RESET}"
else
    echo -e "ALL DATA ON ${DISK1} WILL BE PERMANENTLY DESTROYED! (Other disks remain untouched)${CLR_RESET}"
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

# Erase secondary disk only if in all-disks mode
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    log_info "Wiping partition tables on ${DISK2}..."
    wipefs --all --force "${DISK2}" > /dev/null 2>&1 || true
    sgdisk --zap-all "${DISK2}" > /dev/null 2>&1
fi

sleep 1
partprobe "${DISK1}" 2>/dev/null || true
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    partprobe "${DISK2}" 2>/dev/null || true
fi

log_step "Partitioning Drives"

# Drive 1 Partitioning:
# 1. 1GB EFI System Partition (type ef00)
# 2. Remainder root filesystem (type 8300)
log_info "Partitioning ${DISK1} (1GB EFI + Root)..."
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI-SYSTEM" "${DISK1}"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ARCH-ROOT" "${DISK1}"

# Drive 2 Partitioning (if all-disks mode):
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    log_info "Partitioning ${DISK2} (Full disk data/span)..."
    sgdisk -n 1:0:0 -t 1:8300 -c 1:"ARCH-DATA" "${DISK2}"
fi

sleep 2
partprobe "${DISK1}" 2>/dev/null || true
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    partprobe "${DISK2}" 2>/dev/null || true
fi
sleep 1

# Resolve partition paths
PART_EFI="$(get_partition_name "${DISK1}" 1)"
PART_ROOT="$(get_partition_name "${DISK1}" 2)"
PART_DRIVE2=""
if [[ "${DISK_LAYOUT}" == "all" && -n "${DISK2:-}" ]]; then
    PART_DRIVE2="$(get_partition_name "${DISK2}" 1)"
fi

log_info "Resolved Partition Devices:"
log_info "  EFI Partition:      ${PART_EFI}"
log_info "  Root Device:        ${PART_ROOT}"
if [[ -n "${PART_DRIVE2}" ]]; then
    log_info "  Drive 2 Device:     ${PART_DRIVE2}"
fi

# ------------------------------------------------------------------------------
# Filesystem Creation & Mounting
# ------------------------------------------------------------------------------
log_step "Formatting EFI System Partition"
mkfs.vfat -F32 -n "EFI" "${PART_EFI}"
log_success "EFI partition formatted (FAT32)."

log_step "Creating Filesystem (${FILESYSTEM})"

mkdir -p /mnt

case "${FILESYSTEM}" in
    btrfs)
        case "${BTRFS_MODE}" in
            raid0)
                if [[ -n "${PART_DRIVE2}" ]]; then
                    log_info "Creating spanned Btrfs RAID0 pool across ${PART_ROOT} and ${PART_DRIVE2}..."
                    mkfs.btrfs -f -L "ARCH_ROOT" -d raid0 -m raid1 "${PART_ROOT}" "${PART_DRIVE2}"
                else
                    log_info "Creating single-disk Btrfs filesystem on ${PART_ROOT}..."
                    mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
                fi
                ;;
            single)
                if [[ -n "${PART_DRIVE2}" ]]; then
                    log_info "Creating spanned Btrfs single pool across ${PART_ROOT} and ${PART_DRIVE2}..."
                    mkfs.btrfs -f -L "ARCH_ROOT" -d single -m single "${PART_ROOT}" "${PART_DRIVE2}"
                else
                    log_info "Creating single-disk Btrfs filesystem on ${PART_ROOT}..."
                    mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
                fi
                ;;
            separate)
                log_info "Creating primary Btrfs filesystem on ${PART_ROOT}..."
                mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
                if [[ -n "${PART_DRIVE2}" ]]; then
                    log_info "Creating secondary Btrfs filesystem on ${PART_DRIVE2}..."
                    mkfs.btrfs -f -L "ARCH_DATA" "${PART_DRIVE2}"
                fi
                ;;
            *)
                log_info "Creating single-disk Btrfs filesystem on ${PART_ROOT}..."
                mkfs.btrfs -f -L "ARCH_ROOT" "${PART_ROOT}"
                ;;
        esac

        log_step "Creating Btrfs Subvolume Structure"
        mount -t btrfs "${PART_ROOT}" /mnt
        log_info "Creating subvolumes: @, @home, @snapshots, @var_log, @pkg..."
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        btrfs subvolume create /mnt/@snapshots
        btrfs subvolume create /mnt/@var_log
        btrfs subvolume create /mnt/@pkg
        umount /mnt
        log_success "Subvolumes created."

        log_step "Mounting Subvolumes with Performance Options (${BTRFS_MOUNT_OPTS})"
        mount -o "${BTRFS_MOUNT_OPTS},subvol=@" "${PART_ROOT}" /mnt
        mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache/pacman/pkg}
        mount -o "${BTRFS_MOUNT_OPTS},subvol=@home" "${PART_ROOT}" /mnt/home
        mount -o "${BTRFS_MOUNT_OPTS},subvol=@snapshots" "${PART_ROOT}" /mnt/.snapshots
        mount -o "${BTRFS_MOUNT_OPTS},subvol=@var_log" "${PART_ROOT}" /mnt/var/log
        mount -o "${BTRFS_MOUNT_OPTS},subvol=@pkg" "${PART_ROOT}" /mnt/var/cache/pacman/pkg
        mount "${PART_EFI}" /mnt/boot

        if [[ "${BTRFS_MODE}" == "separate" && -n "${PART_DRIVE2}" ]]; then
            mkdir -p "/mnt${SECONDARY_MOUNT}"
            mount -o "${BTRFS_MOUNT_OPTS}" "${PART_DRIVE2}" "/mnt${SECONDARY_MOUNT}"
            log_info "Secondary drive mounted at /mnt${SECONDARY_MOUNT}."
        fi
        ;;

    ext4)
        log_info "Creating ext4 filesystem on ${PART_ROOT}..."
        mkfs.ext4 -F -L "ARCH_ROOT" "${PART_ROOT}"
        mount -o "${EXT4_MOUNT_OPTS:-noatime,errors=remount-ro}" "${PART_ROOT}" /mnt
        mkdir -p /mnt/{boot,home}
        mount "${PART_EFI}" /mnt/boot

        if [[ "${DISK_LAYOUT}" == "all" && -n "${PART_DRIVE2}" ]]; then
            log_info "Creating secondary ext4 filesystem on ${PART_DRIVE2}..."
            mkfs.ext4 -F -L "ARCH_DATA" "${PART_DRIVE2}"
            mkdir -p "/mnt${SECONDARY_MOUNT}"
            mount -o "${EXT4_MOUNT_OPTS:-noatime,errors=remount-ro}" "${PART_DRIVE2}" "/mnt${SECONDARY_MOUNT}"
            log_info "Secondary drive mounted at /mnt${SECONDARY_MOUNT}."
        fi
        ;;

    xfs)
        log_info "Creating XFS filesystem on ${PART_ROOT}..."
        mkfs.xfs -f -L "ARCH_ROOT" "${PART_ROOT}"
        mount -o "${XFS_MOUNT_OPTS:-noatime}" "${PART_ROOT}" /mnt
        mkdir -p /mnt/{boot,home}
        mount "${PART_EFI}" /mnt/boot

        if [[ "${DISK_LAYOUT}" == "all" && -n "${PART_DRIVE2}" ]]; then
            log_info "Creating secondary XFS filesystem on ${PART_DRIVE2}..."
            mkfs.xfs -f -L "ARCH_DATA" "${PART_DRIVE2}"
            mkdir -p "/mnt${SECONDARY_MOUNT}"
            mount -o "${XFS_MOUNT_OPTS:-noatime}" "${PART_DRIVE2}" "/mnt${SECONDARY_MOUNT}"
            log_info "Secondary drive mounted at /mnt${SECONDARY_MOUNT}."
        fi
        ;;

    f2fs)
        log_info "Creating F2FS filesystem on ${PART_ROOT}..."
        mkfs.f2fs -f -l "ARCH_ROOT" "${PART_ROOT}"
        mount -o "${F2FS_MOUNT_OPTS:-noatime}" "${PART_ROOT}" /mnt
        mkdir -p /mnt/{boot,home}
        mount "${PART_EFI}" /mnt/boot

        if [[ "${DISK_LAYOUT}" == "all" && -n "${PART_DRIVE2}" ]]; then
            log_info "Creating secondary F2FS filesystem on ${PART_DRIVE2}..."
            mkfs.f2fs -f -l "ARCH_DATA" "${PART_DRIVE2}"
            mkdir -p "/mnt${SECONDARY_MOUNT}"
            mount -o "${F2FS_MOUNT_OPTS:-noatime}" "${PART_DRIVE2}" "/mnt${SECONDARY_MOUNT}"
            log_info "Secondary drive mounted at /mnt${SECONDARY_MOUNT}."
        fi
        ;;

    *)
        log_error "Unsupported filesystem: '${FILESYSTEM}'"
        exit 1
        ;;
esac

log_success "All filesystems mounted successfully."

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
    grub
    efibootmgr
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

# Filesystem-specific utilities
case "${FILESYSTEM}" in
    btrfs)
        BASE_PACKAGES+=(btrfs-progs grub-btrfs inotify-tools)
        ;;
    ext4)
        BASE_PACKAGES+=(e2fsprogs)
        ;;
    xfs)
        BASE_PACKAGES+=(xfsprogs)
        ;;
    f2fs)
        BASE_PACKAGES+=(f2fs-tools)
        ;;
esac

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
