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
test_assert_eq "Default DISK1" "/dev/sda" "${DISK1}"
test_assert_eq "Default DISK2" "/dev/sdb" "${DISK2}"
test_assert_eq "Default BTRFS_MODE" "raid0" "${BTRFS_MODE}"
test_assert_eq "BTRFS_MOUNT_OPTS contains zstd" "true" "$([[ "${BTRFS_MOUNT_OPTS}" =~ compress=zstd:3 ]] && echo true || echo false)"
test_assert_eq "Default WM" "bspwm" "${WM}"
test_assert_eq "Default TERMINAL" "kitty" "${TERMINAL}"
test_assert_eq "Default DISPLAY_MANAGER" "sddm" "${DISPLAY_MANAGER}"

# 3. Test AUTO_DETECT_HARDWARE variable
test_assert_eq "AUTO_DETECT_HARDWARE is true by default" "true" "${AUTO_DETECT_HARDWARE}"

# 4. Test lib/detect.sh execution and hardware specification profiling
detect_hardware
apply_hardware_profile

test_assert_eq "CPU vendor is detected non-empty" "true" "$([[ -n "${DETECTED_CPU_VENDOR}" ]] && echo true || echo false)"
test_assert_eq "RAM MB is detected greater than 0" "true" "$([[ "${DETECTED_RAM_MB}" -gt 0 ]] && echo true || echo false)"
test_assert_eq "Disks count is at least 0" "true" "$([[ "${DETECTED_DISK_COUNT}" -ge 0 ]] && echo true || echo false)"
test_assert_eq "GPU setup is detected non-empty" "true" "$([[ -n "${DETECTED_GPU_SETUP}" ]] && echo true || echo false)"
test_assert_eq "CPU Microcode package is set" "true" "$([[ -n "${CPU_UCODE_PACKAGE}" ]] && echo true || echo false)"

# 5. Test saving and reloading hardware profile
MOCK_HW_FILE="/tmp/test_archsetup_hw.env"
save_hardware_profile "$MOCK_HW_FILE"
test_assert_eq "Hardware profile saved successfully" "true" "$([[ -f "$MOCK_HW_FILE" ]] && echo true || echo false)"
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
