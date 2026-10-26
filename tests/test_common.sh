#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/common.sh & config.env
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source common library
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/config.env"

FAILED=0

test_assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo -e "\033[1;32m[PASS]\033[0m ${test_name}"
    else
        echo -e "\033[1;31m[FAIL]\033[0m ${test_name} (Expected: '${expected}', Got: '${actual}')"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== Running Common Unit Tests ==="

# 1. Test get_partition_name
test_assert_eq "SATA disk partition 1" "/dev/sda1" "$(get_partition_name /dev/sda 1)"
test_assert_eq "SATA disk partition 2" "/dev/sda2" "$(get_partition_name /dev/sda 2)"
test_assert_eq "SATA disk partition 1 (sdb)" "/dev/sdb1" "$(get_partition_name /dev/sdb 1)"
test_assert_eq "NVMe disk partition 1" "/dev/nvme0n1p1" "$(get_partition_name /dev/nvme0n1 1)"
test_assert_eq "NVMe disk partition 2" "/dev/nvme0n1p2" "$(get_partition_name /dev/nvme0n1 2)"
test_assert_eq "MMC disk partition 1" "/dev/mmcblk0p1" "$(get_partition_name /dev/mmcblk0 1)"
test_assert_eq "VirtIO disk partition 1" "/dev/vda1" "$(get_partition_name /dev/vda 1)"

# 2. Test config.env variables
test_assert_eq "Default DISK_LAYOUT" "single" "${DISK_LAYOUT}"
test_assert_eq "Default DISK1" "/dev/sda" "${DISK1}"
test_assert_eq "Default DISK2" "/dev/sdb" "${DISK2}"
test_assert_eq "Default FILESYSTEM" "btrfs" "${FILESYSTEM}"
test_assert_eq "Default BTRFS_MODE" "raid0" "${BTRFS_MODE}"
test_assert_eq "BTRFS_MOUNT_OPTS contains zstd" "true" "$([[ "${BTRFS_MOUNT_OPTS}" =~ compress=zstd:3 ]] && echo true || echo false)"
test_assert_eq "Default DESKTOP_ENV" "bspwm" "${DESKTOP_ENV}"
test_assert_eq "Default WM" "bspwm" "${WM}"
test_assert_eq "Default TERMINAL" "kitty" "${TERMINAL}"
test_assert_eq "Default DISPLAY_MANAGER" "lightdm" "${DISPLAY_MANAGER}"
test_assert_eq "Default TEXT_EDITOR" "neovim" "${TEXT_EDITOR}"
test_assert_eq "Default BROWSER" "firefox" "${BROWSER}"

# 3. Test AUTO_DETECT_HARDWARE variable
test_assert_eq "AUTO_DETECT_HARDWARE is true by default" "true" "${AUTO_DETECT_HARDWARE}"

# 3b. Test repository and AUR helper flags
test_assert_eq "ENABLE_MULTILIB is true by default" "true" "${ENABLE_MULTILIB}"
test_assert_eq "ENABLE_CHAOTIC_AUR is true by default" "true" "${ENABLE_CHAOTIC_AUR}"
test_assert_eq "INSTALL_PARU is true by default" "true" "${INSTALL_PARU}"
test_assert_eq "INSTALL_ANTIGRAVITY_CLI is true by default" "true" "${INSTALL_ANTIGRAVITY_CLI}"

# 4. Test lib/detect.sh execution and hardware specification profiling
detect_hardware
apply_hardware_profile

test_assert_eq "CPU vendor is detected non-empty" "true" "$([[ -n "${DETECTED_CPU_VENDOR}" ]] && echo true || echo false)"
test_assert_eq "RAM MB is detected greater than 0" "true" "$([[ "${DETECTED_RAM_MB}" -gt 0 ]] && echo true || echo false)"
test_assert_eq "Disks count is at least 0" "true" "$([[ "${DETECTED_DISK_COUNT}" -ge 0 ]] && echo true || echo false)"
test_assert_eq "GPU setup is detected non-empty" "true" "$([[ -n "${DETECTED_GPU_SETUP}" ]] && echo true || echo false)"
test_assert_eq "CPU Microcode package is set" "true" "$([[ -n "${CPU_UCODE_PACKAGE}" ]] && echo true || echo false)"
test_assert_eq "GRAPHICS_PACKAGES is populated" "true" "$([[ ${#GRAPHICS_PACKAGES[@]} -gt 0 ]] && echo true || echo false)"

# 4b. Test Desktop Environment and Display Manager Dynamic Resolution
DESKTOP_ENV="gnome"
DISPLAY_MANAGER=""
apply_hardware_profile
test_assert_eq "GNOME desktop resolves to GDM display manager" "gdm" "${DISPLAY_MANAGER}"

DESKTOP_ENV="bspwm"
DISPLAY_MANAGER=""
apply_hardware_profile
test_assert_eq "BSPWM desktop resolves to LightDM display manager" "lightdm" "${DISPLAY_MANAGER}"

# 4c. Test Filesystem choices
FILESYSTEM="ext4"
apply_hardware_profile
test_assert_eq "ext4 filesystem retains ext4 selection" "ext4" "${FILESYSTEM}"

FILESYSTEM="xfs"
apply_hardware_profile
test_assert_eq "xfs filesystem retains xfs selection" "xfs" "${FILESYSTEM}"

FILESYSTEM="f2fs"
apply_hardware_profile
test_assert_eq "f2fs filesystem retains f2fs selection" "f2fs" "${FILESYSTEM}"

# 4d. Test Single-Disk vs All-Disks Layout Logic
DISK_LAYOUT="single"
apply_hardware_profile
test_assert_eq "Single disk layout clears DISK2" "" "${DISK2}"
test_assert_eq "Single disk layout sets single_disk btrfs mode" "single_disk" "${BTRFS_MODE}"

# 4e. Test mock GPU offload (PRIME) scenarios
MOCK_INTEL_AMD="00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics 620 [8086:5917]
01:00.0 Display controller [0380]: Advanced Micro Devices, Inc. Radeon R5 M330 [1002:6900]"
detect_gpus "${MOCK_INTEL_AMD}"
apply_hardware_profile
test_assert_eq "Intel+AMD hybrid setup" "intel-amd-hybrid" "${DETECTED_GPU_SETUP}"
test_assert_eq "Intel+AMD PRIME offload type" "amd" "${PRIME_TYPE}"
test_assert_eq "Intel+AMD early KMS modules" "i915 amdgpu" "${KMS_MODULES}"
test_assert_eq "Intel+AMD SI kernel cmdline flags" "radeon.si_support=0 radeon.cik_support=0 amdgpu.si_support=1 amdgpu.cik_support=1" "${KERNEL_CMDLINE_EXTRA}"

MOCK_INTEL_NV="00:02.0 VGA compatible controller [0300]: Intel Corporation UHD [8086:9a60]
01:00.0 3D controller [0302]: NVIDIA Corporation RTX 3060 [10de:2503]"
detect_gpus "${MOCK_INTEL_NV}"
apply_hardware_profile
test_assert_eq "Intel+NVIDIA hybrid setup" "intel-nvidia-hybrid" "${DETECTED_GPU_SETUP}"
test_assert_eq "Intel+NVIDIA PRIME offload type" "nvidia" "${PRIME_TYPE}"

# 5. Test saving and reloading hardware profile
MOCK_HW_FILE="/tmp/test_archsetup_hw.env"
save_hardware_profile "$MOCK_HW_FILE"
test_assert_eq "Hardware profile saved successfully" "true" "$([[ -f "$MOCK_HW_FILE" ]] && echo true || echo false)"
test_assert_eq "Hardware profile contains GRAPHICS_PACKAGES" "true" "$(grep -q "^GRAPHICS_PACKAGES=" "$MOCK_HW_FILE" && echo true || echo false)"
test_assert_eq "Hardware profile contains DISK_LAYOUT" "true" "$(grep -q "^DISK_LAYOUT=" "$MOCK_HW_FILE" && echo true || echo false)"
test_assert_eq "Hardware profile contains FILESYSTEM" "true" "$(grep -q "^FILESYSTEM=" "$MOCK_HW_FILE" && echo true || echo false)"
test_assert_eq "Hardware profile contains DESKTOP_ENV" "true" "$(grep -q "^DESKTOP_ENV=" "$MOCK_HW_FILE" && echo true || echo false)"
test_assert_eq "Hardware profile contains DISPLAY_MANAGER" "true" "$(grep -q "^DISPLAY_MANAGER=" "$MOCK_HW_FILE" && echo true || echo false)"
rm -f "$MOCK_HW_FILE"

# 6. Test logging functions don't fail under pipefail
log_info "Test info message" > /dev/null
log_warn "Test warn message" > /dev/null
log_error "Test error message" 2> /dev/null
log_success "Test success message" > /dev/null
log_step "Test step message" > /dev/null
echo -e "\033[1;32m[PASS]\033[0m Logging functions executed smoothly"

if [[ $FAILED -eq 0 ]]; then
    echo -e "\033[1;32mAll Common Unit Tests Passed Successfully!\033[0m\n"
    exit 0
else
    echo -e "\033[1;31m$FAILED Unit Test(s) Failed!\033[0m\n"
    exit 1
fi
