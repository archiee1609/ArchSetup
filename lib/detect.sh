#!/usr/bin/env bash
# ==============================================================================
# Hardware Auto-Detection & Specification Recognition Library
# Dynamically inspects CPU, GPU, Storage, RAM, Chassis, and Virtualization
# to tailor the Arch Linux installation profile for any target system.
# ==============================================================================

set -euo pipefail

# Ensure common library colors/logging are available if sourced standalone
if ! declare -f log_info > /dev/null 2>&1; then
    CLR_RESET="\033[0m"
    CLR_INFO="\033[1;34m"
    CLR_WARN="\033[1;33m"
    CLR_ERROR="\033[1;31m"
    CLR_SUCCESS="\033[1;32m"
    CLR_STEP="\033[1;36m"
    CLR_BOLD="\033[1m"
    CLR_DIM="\033[2m"
    log_info() { printf "${CLR_INFO}[INFO]${CLR_RESET} %s\n" "$*"; }
    log_warn() { printf "${CLR_WARN}[WARN]${CLR_RESET} %s\n" "$*"; }
    log_error() { printf "${CLR_ERROR}[ERROR]${CLR_RESET} %s\n" "$*" >&2; }
    log_success() { printf "${CLR_SUCCESS}[SUCCESS]${CLR_RESET} %s\n" "$*"; }
    log_step() { printf "\n${CLR_STEP}==>${CLR_RESET} ${CLR_BOLD}%s${CLR_RESET}\n" "$*"; }
fi

# Global Detection State
DETECTED_CPU_VENDOR=""
DETECTED_CPU_MODEL=""
DETECTED_CPU_CORES=1
DETECTED_CPU_UCODE=""

DETECTED_RAM_MB=0
DETECTED_RAM_GB="0.0 GB"
DETECTED_ZRAM_FRACTION="0.5"
DETECTED_ZRAM_ALGORITHM="zstd"

DETECTED_VIRT="none"
DETECTED_IS_VM=0
DETECTED_CHASSIS="desktop"
DETECTED_HAS_BATTERY=0
DETECTED_BATTERY_NAME=""
DETECTED_ADAPTER_NAME=""

DETECTED_GPUS=()
DETECTED_HAS_INTEL_GPU=0
DETECTED_HAS_AMD_GPU=0
DETECTED_HAS_NVIDIA_GPU=0
DETECTED_HAS_VM_GPU=0
DETECTED_AMD_IS_LEGACY_SI_CIK=0
DETECTED_GPU_SETUP="generic"
DETECTED_GRAPHICS_PACKAGES=()
DETECTED_KMS_MODULES=""
DETECTED_KERNEL_CMDLINE_EXTRA=""
DETECTED_PRIME_TYPE="none"

DETECTED_DISKS=()
DETECTED_DISK_DETAILS=()
DETECTED_DISK_COUNT=0
DETECTED_PRIMARY_DISK=""
DETECTED_SECONDARY_DISK=""
DETECTED_PRIMARY_DISK_ROTA=0
DETECTED_RECOMMENDED_BTRFS_MODE="single_disk"
DETECTED_BTRFS_MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"

DETECTED_HAS_WIFI=0
DETECTED_HAS_ETHERNET=0

# ------------------------------------------------------------------------------
# 1. CPU & Microcode Detection
# ------------------------------------------------------------------------------
detect_cpu() {
    local mock_cpu_info="${1:-}"

    DETECTED_CPU_VENDOR="Unknown"
    DETECTED_CPU_MODEL="Generic x86_64"
    DETECTED_CPU_CORES=1
    DETECTED_CPU_UCODE="intel-ucode"

    local vendor=""
    local model=""
    local cores=""

    if [[ -n "$mock_cpu_info" ]]; then
        vendor=$(echo "$mock_cpu_info" | awk -F': ' '/vendor_id/ {print $2; exit}' || echo "$mock_cpu_info")
        model=$(echo "$mock_cpu_info" | awk -F': ' '/model name/ {print $2; exit}' || echo "$mock_cpu_info")
        cores=4
    elif [[ -f /proc/cpuinfo ]]; then
        vendor=$(awk -F': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
        model=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
        if [[ -z "$model" ]]; then
            model=$(lscpu 2>/dev/null | awk -F': +' '/Model name/ {print $2}' || echo "Generic x86_64")
        fi
        cores=$(nproc 2>/dev/null || awk -F': ' '/cpu cores/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo 1)
    fi

    case "$vendor" in
        *GenuineIntel*|*Intel*)
            DETECTED_CPU_VENDOR="Intel"
            DETECTED_CPU_UCODE="intel-ucode"
            ;;
        *AuthenticAMD*|*AMD*)
            DETECTED_CPU_VENDOR="AMD"
            DETECTED_CPU_UCODE="amd-ucode"
            ;;
        *)
            DETECTED_CPU_VENDOR="Other (${vendor:-Unknown})"
            DETECTED_CPU_UCODE=""
            ;;
    esac

    DETECTED_CPU_MODEL="${model:-Generic x86_64}"
    DETECTED_CPU_CORES="${cores:-1}"
}

# ------------------------------------------------------------------------------
# 2. RAM & Memory Strategy Detection
# ------------------------------------------------------------------------------
detect_ram() {
    local mock_ram_mb="${1:-}"

    DETECTED_RAM_MB=0
    DETECTED_RAM_GB="0.0 GB"
    DETECTED_ZRAM_FRACTION="0.5"
    DETECTED_ZRAM_ALGORITHM="zstd"

    if [[ -n "$mock_ram_mb" ]]; then
        DETECTED_RAM_MB="$mock_ram_mb"
        DETECTED_RAM_GB=$(awk -v m="$mock_ram_mb" 'BEGIN {printf "%.1f GB", m/1024}')
    elif [[ -f /proc/meminfo ]]; then
        local kb
        kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
        DETECTED_RAM_MB=$(( kb / 1024 ))
        DETECTED_RAM_GB=$(awk -v k="$kb" 'BEGIN {printf "%.1f GB", k/1024/1024}')
    fi

    # Systems with <= 4GB RAM benefit from 100% zram compression to prevent OOM
    if [[ "$DETECTED_RAM_MB" -le 4096 ]]; then
        DETECTED_ZRAM_FRACTION="1.0"
    elif [[ "$DETECTED_RAM_MB" -le 8192 ]]; then
        DETECTED_ZRAM_FRACTION="0.75"
    else
        DETECTED_ZRAM_FRACTION="0.5"
    fi
}

# ------------------------------------------------------------------------------
# 3. Chassis, Battery & Virtualization Detection
# ------------------------------------------------------------------------------
detect_chassis_and_virt() {
    DETECTED_VIRT="none"
    DETECTED_IS_VM=0
    DETECTED_CHASSIS="desktop"
    DETECTED_HAS_BATTERY=0
    DETECTED_BATTERY_NAME=""
    DETECTED_ADAPTER_NAME=""

    # Check systemd virtualization detection
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo "none")
    if [[ "$virt" != "none" && -n "$virt" ]]; then
        DETECTED_VIRT="$virt"
        DETECTED_IS_VM=1
        DETECTED_CHASSIS="virtual-machine"
    else
        # Fallback DMI check
        local sys_vendor product_name
        sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
        product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
        if [[ "$sys_vendor" =~ (QEMU|innotek|VirtualBox|VMware|Bochs) || "$product_name" =~ (VirtualBox|VMware|KVM|Bochs) ]]; then
            DETECTED_IS_VM=1
            DETECTED_CHASSIS="virtual-machine"
            if [[ "$sys_vendor" =~ VirtualBox || "$product_name" =~ VirtualBox ]]; then
                DETECTED_VIRT="oracle"
            elif [[ "$sys_vendor" =~ VMware || "$product_name" =~ VMware ]]; then
                DETECTED_VIRT="vmware"
            elif [[ "$sys_vendor" =~ QEMU || "$product_name" =~ KVM ]]; then
                DETECTED_VIRT="kvm"
            fi
        fi
    fi

    # Battery & AC detection
    for b in /sys/class/power_supply/BAT* /sys/class/power_supply/battery*; do
        if [[ -d "$b" ]]; then
            DETECTED_HAS_BATTERY=1
            DETECTED_BATTERY_NAME="$(basename "$b")"
            break
        fi
    done

    for a in /sys/class/power_supply/AC* /sys/class/power_supply/ADP* /sys/class/power_supply/acad*; do
        if [[ -d "$a" ]]; then
            DETECTED_ADAPTER_NAME="$(basename "$a")"
            break
        fi
    done

    # Default adapter fallback if none detected
    if [[ -z "$DETECTED_ADAPTER_NAME" ]]; then
        DETECTED_ADAPTER_NAME="AC"
    fi

    # If physical machine, inspect SMBIOS chassis type
    if [[ "$DETECTED_IS_VM" -eq 0 ]]; then
        local chassis_type
        chassis_type=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo "0")
        case "$chassis_type" in
            8|9|10|11|14|30|31|32)
                DETECTED_CHASSIS="laptop"
                ;;
            3|4|5|6|7|15|16|24)
                DETECTED_CHASSIS="desktop"
                ;;
            17|23|28|29)
                DETECTED_CHASSIS="server"
                ;;
            *)
                if [[ "$DETECTED_HAS_BATTERY" -eq 1 ]]; then
                    DETECTED_CHASSIS="laptop"
                else
                    DETECTED_CHASSIS="desktop"
                fi
                ;;
        esac
    fi
}

# ------------------------------------------------------------------------------
# 4. GPU & Graphics Stack Detection
# ------------------------------------------------------------------------------
detect_gpus() {
    DETECTED_GPUS=()
    DETECTED_HAS_INTEL_GPU=0
    DETECTED_HAS_AMD_GPU=0
    DETECTED_HAS_NVIDIA_GPU=0
    DETECTED_HAS_VM_GPU=0
    DETECTED_AMD_IS_LEGACY_SI_CIK=0
    DETECTED_GPU_SETUP="generic"
    DETECTED_GRAPHICS_PACKAGES=()
    DETECTED_KMS_MODULES=""
    DETECTED_KERNEL_CMDLINE_EXTRA=""
    DETECTED_PRIME_TYPE="none"

    local pci_display="${1:-}"
    if [[ -z "$pci_display" ]]; then
        pci_display=$(lspci -nn 2>/dev/null | grep -E "\[0300\]|\[0302\]|\[0380\]" || true)
    fi

    if [[ -z "$pci_display" ]]; then
        # Check /sys/class/drm as fallback
        if compgen -G "/sys/class/drm/card*" > /dev/null; then
            pci_display="00:02.0 VGA compatible controller: Generic DRM Graphics"
        fi
    fi

    local si_cik_pattern="Oland|Cape Verde|Pitcairn|Tahiti|Hainan|Curacao|Malta|Bonaire|Hawaii|Kaveri|Kabini|Mullins|Temash|R5 M330|R5 M230|HD 7[0-9]{3}|HD 8[0-9]{3}|R7 2[0-9]{2}|R9 2[0-9]{2}|R9 3[0-9]{2}"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        DETECTED_GPUS+=("$line")

        # Identify Intel GPU (Vendor 8086)
        if [[ "$line" =~ \[8086: || "$line" =~ Intel ]]; then
            DETECTED_HAS_INTEL_GPU=1
        fi

        # Identify AMD GPU (Vendor 1002)
        if [[ "$line" =~ \[1002: || "$line" =~ AMD || "$line" =~ ATI || "$line" =~ Radeon ]]; then
            DETECTED_HAS_AMD_GPU=1
            if echo "$line" | grep -Ei -q "$si_cik_pattern" || [[ "${ENABLE_AMDGPU_SI:-false}" == "true" ]]; then
                DETECTED_AMD_IS_LEGACY_SI_CIK=1
            fi
        fi

        # Identify NVIDIA GPU (Vendor 10de)
        if [[ "$line" =~ \[10de: || "$line" =~ NVIDIA ]]; then
            DETECTED_HAS_NVIDIA_GPU=1
        fi

        # Identify Virtualization GPU
        if [[ "$line" =~ VMware || "$line" =~ VirtualBox || "$line" =~ Virtio || "$line" =~ QEMU || "$line" =~ Bochs || "$line" =~ \[15ad: || "$line" =~ \[80ee: || "$line" =~ \[1af4: ]]; then
            DETECTED_HAS_VM_GPU=1
        fi
    done <<< "$pci_display"

    # Base graphics packages common to all modern graphical environments
    DETECTED_GRAPHICS_PACKAGES=(
        mesa
        mesa-utils
        lib32-mesa
    )

    # Classify GPU Topology and Configure KMS / Prime / Cmdline
    if [[ "$DETECTED_HAS_INTEL_GPU" -eq 1 && "$DETECTED_HAS_AMD_GPU" -eq 1 ]]; then
        DETECTED_GPU_SETUP="intel-amd-hybrid"
        DETECTED_PRIME_TYPE="amd"
        DETECTED_KMS_MODULES="i915 amdgpu"
        DETECTED_GRAPHICS_PACKAGES+=(
            vulkan-intel
            intel-media-driver
            lib32-vulkan-intel
            xf86-video-amdgpu
            vulkan-radeon
            libva-mesa-driver
            lib32-vulkan-radeon
            vulkan-tools
            libva-utils
        )
        if [[ "$DETECTED_AMD_IS_LEGACY_SI_CIK" -eq 1 ]]; then
            DETECTED_KERNEL_CMDLINE_EXTRA="radeon.si_support=0 radeon.cik_support=0 amdgpu.si_support=1 amdgpu.cik_support=1"
        fi

    elif [[ "$DETECTED_HAS_INTEL_GPU" -eq 1 && "$DETECTED_HAS_NVIDIA_GPU" -eq 1 ]]; then
        DETECTED_GPU_SETUP="intel-nvidia-hybrid"
        DETECTED_PRIME_TYPE="nvidia"
        DETECTED_KMS_MODULES="i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm"
        DETECTED_KERNEL_CMDLINE_EXTRA="nvidia_drm.modeset=1"
        DETECTED_GRAPHICS_PACKAGES+=(
            vulkan-intel
            intel-media-driver
            lib32-vulkan-intel
            nvidia-dkms
            nvidia-utils
            lib32-nvidia-utils
            nvidia-settings
            vulkan-tools
            libva-utils
        )

    elif [[ "$DETECTED_HAS_AMD_GPU" -eq 1 && "$DETECTED_HAS_NVIDIA_GPU" -eq 1 ]]; then
        DETECTED_GPU_SETUP="amd-nvidia-hybrid"
        DETECTED_PRIME_TYPE="nvidia"
        DETECTED_KMS_MODULES="amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm"
        DETECTED_KERNEL_CMDLINE_EXTRA="nvidia_drm.modeset=1"
        DETECTED_GRAPHICS_PACKAGES+=(
            xf86-video-amdgpu
            vulkan-radeon
            libva-mesa-driver
            lib32-vulkan-radeon
            nvidia-dkms
            nvidia-utils
            lib32-nvidia-utils
            nvidia-settings
            vulkan-tools
            libva-utils
        )

    elif [[ "$DETECTED_HAS_INTEL_GPU" -eq 1 ]]; then
        DETECTED_GPU_SETUP="intel-only"
        DETECTED_PRIME_TYPE="none"
        DETECTED_KMS_MODULES="i915"
        DETECTED_GRAPHICS_PACKAGES+=(
            vulkan-intel
            intel-media-driver
            lib32-vulkan-intel
            vulkan-tools
            libva-utils
        )

    elif [[ "$DETECTED_HAS_AMD_GPU" -eq 1 ]]; then
        DETECTED_GPU_SETUP="amd-only"
        DETECTED_PRIME_TYPE="none"
        DETECTED_KMS_MODULES="amdgpu"
        DETECTED_GRAPHICS_PACKAGES+=(
            xf86-video-amdgpu
            vulkan-radeon
            libva-mesa-driver
            lib32-vulkan-radeon
            vulkan-tools
            libva-utils
        )
        if [[ "$DETECTED_AMD_IS_LEGACY_SI_CIK" -eq 1 ]]; then
            DETECTED_KERNEL_CMDLINE_EXTRA="radeon.si_support=0 radeon.cik_support=0 amdgpu.si_support=1 amdgpu.cik_support=1"
        fi

    elif [[ "$DETECTED_HAS_NVIDIA_GPU" -eq 1 ]]; then
        DETECTED_GPU_SETUP="nvidia-only"
        DETECTED_PRIME_TYPE="none"
        DETECTED_KMS_MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
        DETECTED_KERNEL_CMDLINE_EXTRA="nvidia_drm.modeset=1"
        DETECTED_GRAPHICS_PACKAGES+=(
            nvidia-dkms
            nvidia-utils
            lib32-nvidia-utils
            nvidia-settings
            vulkan-tools
            libva-utils
        )

    elif [[ "$DETECTED_HAS_VM_GPU" -eq 1 || "$DETECTED_IS_VM" -eq 1 ]]; then
        DETECTED_GPU_SETUP="virtual-gpu"
        DETECTED_PRIME_TYPE="none"
        DETECTED_KMS_MODULES=""
        if [[ "$DETECTED_VIRT" == "oracle" ]]; then
            DETECTED_GRAPHICS_PACKAGES+=(virtualbox-guest-utils)
        elif [[ "$DETECTED_VIRT" == "vmware" ]]; then
            DETECTED_GRAPHICS_PACKAGES+=(open-vm-tools xf86-video-vmware)
        elif [[ "$DETECTED_VIRT" == "kvm" || "$DETECTED_VIRT" == "qemu" ]]; then
            DETECTED_GRAPHICS_PACKAGES+=(qemu-guest-agent)
        else
            DETECTED_GRAPHICS_PACKAGES+=(xf86-video-vesa)
        fi

    else
        DETECTED_GPU_SETUP="generic"
        DETECTED_PRIME_TYPE="none"
        DETECTED_KMS_MODULES=""
        DETECTED_GRAPHICS_PACKAGES+=(xf86-video-vesa xf86-video-fbdev)
    fi
}

# ------------------------------------------------------------------------------
# 5. Storage & Disks Detection
# ------------------------------------------------------------------------------
detect_disks() {
    DETECTED_DISKS=()
    DETECTED_DISK_DETAILS=()
    DETECTED_DISK_COUNT=0
    DETECTED_PRIMARY_DISK=""
    DETECTED_SECONDARY_DISK=""
    DETECTED_PRIMARY_DISK_ROTA=0
    DETECTED_RECOMMENDED_BTRFS_MODE="single_disk"
    DETECTED_BTRFS_MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"

    # Identify Arch Live USB media to safely exclude it from target candidates
    local live_disk=""
    if [[ -d /run/archiso ]]; then
        local live_mnt
        live_mnt=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
        if [[ -n "$live_mnt" ]]; then
            live_disk=$(lsblk -n -p -o PKNAME "$live_mnt" 2>/dev/null || true)
            if [[ -z "$live_disk" ]]; then
                live_disk="$live_mnt"
            fi
        fi
    fi

    local lines
    lines=$(lsblk -d -n -p -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL 2>/dev/null || true)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local dev type size rota tran model
        dev=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{print $2}')
        size=$(echo "$line" | awk '{print $3}')
        rota=$(echo "$line" | awk '{print $4}')
        tran=$(echo "$line" | awk '{print $5}')
        model=$(echo "$line" | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed 's/^[ \t]*//')

        # Filter non-disks, loop, zram, ram, optical
        [[ "$type" != "disk" ]] && continue
        [[ "$dev" =~ /dev/(zram|loop|ram) ]] && continue

        # Exclude live installation media
        if [[ -n "$live_disk" && "$dev" == "$live_disk"* ]]; then
            continue
        fi

        DETECTED_DISKS+=("$dev")
        DETECTED_DISK_DETAILS+=("${dev} [${size}, ${tran:-internal}, $([[ "$rota" == "0" ]] && echo "SSD/NVMe" || echo "HDD") ${model}]")
    done <<< "$lines"

    DETECTED_DISK_COUNT=${#DETECTED_DISKS[@]}

    if [[ "$DETECTED_DISK_COUNT" -ge 1 ]]; then
        DETECTED_PRIMARY_DISK="${DETECTED_DISKS[0]}"
        local d1_rota
        d1_rota=$(lsblk -d -n -o ROTA "${DETECTED_PRIMARY_DISK}" 2>/dev/null || echo 0)
        DETECTED_PRIMARY_DISK_ROTA="${d1_rota}"

        if [[ "$d1_rota" == "1" ]]; then
            # Rotational HDD: omit discard=async
            DETECTED_BTRFS_MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2"
        else
            # Non-rotational SSD/NVMe: include discard=async
            DETECTED_BTRFS_MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"
        fi
    fi

    if [[ "$DETECTED_DISK_COUNT" -ge 2 ]]; then
        DETECTED_SECONDARY_DISK="${DETECTED_DISKS[1]}"
        local d2_rota
        d2_rota=$(lsblk -d -n -o ROTA "${DETECTED_SECONDARY_DISK}" 2>/dev/null || echo 0)
        if [[ "$DETECTED_PRIMARY_DISK_ROTA" == "0" && "$d2_rota" == "0" ]]; then
            DETECTED_RECOMMENDED_BTRFS_MODE="raid0"
        else
            DETECTED_RECOMMENDED_BTRFS_MODE="single"
        fi
    else
        DETECTED_SECONDARY_DISK=""
        DETECTED_RECOMMENDED_BTRFS_MODE="single_disk"
    fi
}

# ------------------------------------------------------------------------------
# 6. Network Interfaces Detection
# ------------------------------------------------------------------------------
detect_network_devices() {
    DETECTED_HAS_WIFI=0
    DETECTED_HAS_ETHERNET=0

    if compgen -G "/sys/class/net/wl*" > /dev/null || compgen -G "/sys/class/net/wlan*" > /dev/null; then
        DETECTED_HAS_WIFI=1
    fi
    if compgen -G "/sys/class/net/en*" > /dev/null || compgen -G "/sys/class/net/eth*" > /dev/null; then
        DETECTED_HAS_ETHERNET=1
    fi
}

# ------------------------------------------------------------------------------
# 7. Master Hardware Detection
# ------------------------------------------------------------------------------
detect_hardware() {
    detect_cpu
    detect_ram
    detect_chassis_and_virt
    detect_gpus
    detect_disks
    detect_network_devices
}

# ------------------------------------------------------------------------------
# 8. Report Formatter
# ------------------------------------------------------------------------------
print_hardware_report() {
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}         AUTOMATIC HARDWARE SPECIFICATION DISCOVERY & PROFILING       ${CLR_RESET}"
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"

    # Chassis / Virtualization
    if [[ "$DETECTED_IS_VM" -eq 1 ]]; then
        echo -e "  Platform / Chassis:     ${CLR_BOLD}Virtual Machine${CLR_RESET} (Hypervisor: ${DETECTED_VIRT})"
    else
        echo -e "  Platform / Chassis:     ${CLR_BOLD}${DETECTED_CHASSIS^}${CLR_RESET} (Battery: $([[ "$DETECTED_HAS_BATTERY" -eq 1 ]] && echo "Present [${DETECTED_BATTERY_NAME}]" || echo "None"))"
    fi

    # CPU
    echo -e "  Processor (CPU):        ${CLR_BOLD}${DETECTED_CPU_MODEL}${CLR_RESET} (${DETECTED_CPU_CORES} threads, Vendor: ${DETECTED_CPU_VENDOR})"
    echo -e "  Microcode Package:      ${CLR_BOLD}${DETECTED_CPU_UCODE:-None}${CLR_RESET}"

    # RAM
    echo -e "  Physical Memory (RAM):  ${CLR_BOLD}${DETECTED_RAM_GB}${CLR_RESET} (${DETECTED_RAM_MB} MB)"
    echo -e "  ZRAM Swap Strategy:     ${CLR_BOLD}$(awk -v f="$DETECTED_ZRAM_FRACTION" 'BEGIN {printf "%.0f%%", f*100}') RAM${CLR_RESET} (${DETECTED_ZRAM_ALGORITHM})"

    # Storage
    echo -e "  Detected Disks:         ${CLR_BOLD}${DETECTED_DISK_COUNT} usable drive(s) found${CLR_RESET}"
    for d in "${DETECTED_DISK_DETAILS[@]}"; do
        echo -e "    * ${d}"
    done
    echo -e "  Primary Target Disk:    ${CLR_BOLD}${DETECTED_PRIMARY_DISK:-None}${CLR_RESET}"
    if [[ -n "$DETECTED_SECONDARY_DISK" ]]; then
        echo -e "  Secondary Disk:         ${CLR_BOLD}${DETECTED_SECONDARY_DISK}${CLR_RESET}"
    fi
    echo -e "  Btrfs Pool Strategy:    ${CLR_BOLD}${DETECTED_RECOMMENDED_BTRFS_MODE}${CLR_RESET}"
    echo -e "  Mount Options:          ${DETECTED_BTRFS_MOUNT_OPTS}"

    # Graphics
    echo -e "  Graphics Architecture:  ${CLR_BOLD}${DETECTED_GPU_SETUP}${CLR_RESET}"
    for g in "${DETECTED_GPUS[@]}"; do
        echo -e "    * ${g}"
    done
    echo -e "  Early KMS Modules:      ${CLR_BOLD}${DETECTED_KMS_MODULES:-None}${CLR_RESET}"
    if [[ -n "$DETECTED_KERNEL_CMDLINE_EXTRA" ]]; then
        echo -e "  Kernel Cmdline Flags:   ${CLR_BOLD}${DETECTED_KERNEL_CMDLINE_EXTRA}${CLR_RESET}"
    fi
    echo -e "  PRIME Offloading:       ${CLR_BOLD}${DETECTED_PRIME_TYPE}${CLR_RESET}"

    # Power Management Plan
    if [[ "$DETECTED_IS_VM" -eq 1 ]]; then
        echo -e "  Power & Thermal Plan:   Guest Agent Services (TLP/thermald disabled for VM)"
    elif [[ "$DETECTED_CHASSIS" == "laptop" && "$DETECTED_CPU_VENDOR" == "Intel" ]]; then
        echo -e "  Power & Thermal Plan:   TLP (intel_pstate) + thermald thermal mitigation"
    elif [[ "$DETECTED_CHASSIS" == "laptop" ]]; then
        echo -e "  Power & Thermal Plan:   TLP (laptop power profile, thermald skipped for AMD)"
    else
        echo -e "  Power & Thermal Plan:   TLP (standard desktop profile)"
    fi

    # Network
    echo -e "  Networking:             $([[ "$DETECTED_HAS_WIFI" -eq 1 ]] && echo "Wi-Fi + " || echo "")Ethernet"
    echo -e "${CLR_STEP}======================================================================${CLR_RESET}"
}

# ------------------------------------------------------------------------------
# 9. Profile Application (Adapting configuration dynamically)
# ------------------------------------------------------------------------------
apply_hardware_profile() {
    # 1. CPU Microcode
    CPU_UCODE_PACKAGE="${DETECTED_CPU_UCODE:-intel-ucode}"

    # 2. ZRAM Strategy
    if [[ -z "${ZRAM_FRACTION:-}" || "${ZRAM_FRACTION:-}" == "0.5" ]]; then
        ZRAM_FRACTION="${DETECTED_ZRAM_FRACTION}"
    fi
    ZRAM_ALGORITHM="${ZRAM_ALGORITHM:-${DETECTED_ZRAM_ALGORITHM}}"

    # 3. Storage
    # If DISK1 is not set or points to a non-existent device, use detected primary disk
    if [[ -z "${DISK1:-}" || ( "${DRY_RUN:-0}" != "1" && ! -b "${DISK1:-}" && -n "${DETECTED_PRIMARY_DISK:-}" ) ]]; then
        DISK1="${DETECTED_PRIMARY_DISK:-${DISK1:-/dev/sda}}"
    fi

    # If only 1 disk is detected or secondary disk matches primary
    if [[ "$DETECTED_DISK_COUNT" -le 1 ]]; then
        DISK2=""
        BTRFS_MODE="single_disk"
    else
        # Multi-disk mode
        DISK2="${DISK2:-${DETECTED_SECONDARY_DISK}}"
        if [[ -z "${DISK2}" || "${DISK2}" == "${DISK1}" ]]; then
            DISK2=""
            BTRFS_MODE="single_disk"
        else
            BTRFS_MODE="${BTRFS_MODE:-${DETECTED_RECOMMENDED_BTRFS_MODE}}"
        fi
    fi

    # Tune mount options: if rotational disk, use mount options without discard=async
    if [[ "${DETECTED_PRIMARY_DISK_ROTA}" == "1" ]]; then
        BTRFS_MOUNT_OPTS="${DETECTED_BTRFS_MOUNT_OPTS}"
    else
        BTRFS_MOUNT_OPTS="${BTRFS_MOUNT_OPTS:-${DETECTED_BTRFS_MOUNT_OPTS}}"
    fi

    # 4. Graphics & KMS
    KMS_MODULES="${DETECTED_KMS_MODULES}"
    KERNEL_CMDLINE_EXTRA="${DETECTED_KERNEL_CMDLINE_EXTRA}"
    PRIME_TYPE="${DETECTED_PRIME_TYPE}"
    GRAPHICS_PACKAGES=("${DETECTED_GRAPHICS_PACKAGES[@]}")

    # 5. Chassis, Battery & Virtualization
    IS_VM="${DETECTED_IS_VM}"
    VIRT_TYPE="${DETECTED_VIRT}"
    CHASSIS_TYPE="${DETECTED_CHASSIS}"
    HAS_BATTERY="${DETECTED_HAS_BATTERY}"
    BATTERY_NAME="${DETECTED_BATTERY_NAME}"
    ADAPTER_NAME="${DETECTED_ADAPTER_NAME}"
}

# ------------------------------------------------------------------------------
# 10. Profile Persistence (Export for Stage 1 / Stage 2 / Chroot)
# ------------------------------------------------------------------------------
save_hardware_profile() {
    local target_file="$1"
    mkdir -p "$(dirname "$target_file")"

    cat <<EOF > "$target_file"
# Automatically generated hardware specification profile
DETECTED_CPU_VENDOR="${DETECTED_CPU_VENDOR}"
DETECTED_CPU_MODEL="${DETECTED_CPU_MODEL}"
DETECTED_CPU_CORES="${DETECTED_CPU_CORES}"
DETECTED_CPU_UCODE="${DETECTED_CPU_UCODE}"
CPU_UCODE_PACKAGE="${CPU_UCODE_PACKAGE}"

DETECTED_RAM_MB="${DETECTED_RAM_MB}"
DETECTED_RAM_GB="${DETECTED_RAM_GB}"
ZRAM_FRACTION="${ZRAM_FRACTION}"
ZRAM_ALGORITHM="${ZRAM_ALGORITHM}"

DETECTED_VIRT="${DETECTED_VIRT}"
DETECTED_IS_VM="${DETECTED_IS_VM}"
IS_VM="${IS_VM}"
VIRT_TYPE="${VIRT_TYPE}"
CHASSIS_TYPE="${CHASSIS_TYPE}"
HAS_BATTERY="${HAS_BATTERY}"
BATTERY_NAME="${BATTERY_NAME}"
ADAPTER_NAME="${ADAPTER_NAME}"

DETECTED_GPU_SETUP="${DETECTED_GPU_SETUP}"
DETECTED_HAS_INTEL_GPU="${DETECTED_HAS_INTEL_GPU}"
DETECTED_HAS_AMD_GPU="${DETECTED_HAS_AMD_GPU}"
DETECTED_HAS_NVIDIA_GPU="${DETECTED_HAS_NVIDIA_GPU}"
DETECTED_HAS_VM_GPU="${DETECTED_HAS_VM_GPU}"
DETECTED_AMD_IS_LEGACY_SI_CIK="${DETECTED_AMD_IS_LEGACY_SI_CIK}"
PRIME_TYPE="${PRIME_TYPE}"
KMS_MODULES="${KMS_MODULES}"
KERNEL_CMDLINE_EXTRA="${KERNEL_CMDLINE_EXTRA}"

DISK1="${DISK1}"
DISK2="${DISK2}"
BTRFS_MODE="${BTRFS_MODE}"
BTRFS_MOUNT_OPTS="${BTRFS_MOUNT_OPTS}"
EOF
    chmod 644 "$target_file"
}
