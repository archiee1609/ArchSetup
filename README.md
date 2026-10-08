# Adaptive & Modular Arch Linux Deployment Suite
### Hardware-Aware Automated Installer & Tuned Tiling Environment

This repository provides an automated, modular, and robust installation suite for Arch Linux. Equipped with an **intelligent hardware specification recognition engine**, the installer automatically discovers system components (CPU architecture, RAM, storage drives, GPU topology, chassis, and virtualization) before installation begins, dynamically adapting drivers, microcode, kernel parameters, initramfs hooks, and power profiles to match the host machine.

---

## 1. Automatic Hardware Specification Recognition

Before performing any destructive disk operations, the installer runs a comprehensive hardware probe (`lib/detect.sh`) and generates a tailored hardware profile:

| Component | Auto-Detection Logic | Adaptive Configuration Strategy |
| :--- | :--- | :--- |
| **CPU Architecture** | Probes vendor via `/proc/cpuinfo` & `lscpu` (Intel vs AMD) | Installs `intel-ucode` or `amd-ucode`. Tunes CPU governors and power tools. |
| **RAM & ZRAM** | Reads memory capacity from `/proc/meminfo` | Configures `zram-generator` with 100% allocation for <= 4 GB RAM (OOM prevention) or 50% for standard/large RAM with `zstd`. |
| **Storage & Disks** | Discovers NVMe, SATA SSD, and HDD block devices (excludes live USB) | **Single-Disk Mode**: 1GB EFI + Btrfs root with subvolumes (`@`, `@home`, `@snapshots`, etc.).<br>**Multi-Disk Mode**: Automatic RAID0 striped pool or single spanning. Adapts `discard=async` for SSDs/NVMe vs HDDs. |
| **GPU & Display** | Scans PCI display devices via `lspci` (Intel, AMD, NVIDIA, Virtualization) | **Intel iGPU**: `mesa`, `vulkan-intel`, `intel-media-driver`, Early KMS `i915`.<br>**AMD dGPU/APU**: `vulkan-radeon`, `amdgpu`. Legacy GCN 1.0/2.0 automatically receives SI/CIK kernel flags.<br>**NVIDIA**: `nvidia-dkms`, `nvidia-utils`, `nvidia_drm.modeset=1`.<br>**Hybrid PRIME**: Deploys tailored `/usr/local/bin/prime-run` for AMD (`DRI_PRIME=1`) or NVIDIA.<br>**VMs**: Installs `virtualbox-guest-utils`, `open-vm-tools`, or `qemu-guest-agent`. |
| **Chassis & Power** | Inspects DMI chassis type, battery status (`/sys/class/power_supply`) & VM hypervisor | **Laptops**: Enables `tlp`, `powertop`, `brightnessctl`, and `thermald` (Intel-only).<br>**Desktops**: Standard performance profile, disables battery throttling.<br>**Virtual Machines**: Disables laptop thermal/power daemons and activates hypervisor guest services. |
| **Status Bar (Polybar)** | Verifies physical battery presence | Connects detected battery (`BAT0`/`BAT1`) and adapter (`AC`/`ADP1`), or cleanly removes the battery widget on desktops/VMs. |

---

## 2. Repository Layout

```
ArchSetup/
├── config.env                      # Centralized variables, disks, credentials & desktop settings
├── install.sh                      # Master interactive installer with hardware auto-detection
├── stage1_disk_base.sh             # Stage 1: Hardware-aware disks, Btrfs subvolumes, pacstrap & fstab
├── stage2_chroot.sh                # Stage 2: Tailored drivers, kernel KMS, GRUB, services & dotfiles
├── lib/
│   ├── common.sh                   # Shared logging, UEFI checks, block device helpers
│   └── detect.sh                   # Hardware auto-detection & specification profiling engine
└── configs/
    ├── amdgpu/
    │   └── prime-run               # Base DRI_PRIME wrapper
    ├── boot/
    │   ├── grub.default            # GRUB template config
    │   └── mkinitcpio.conf         # Initramfs template with Btrfs & KMS hooks
    ├── dotfiles/
    │   ├── bspwm/bspwmrc           # BSPWM configuration script (Catppuccin Mocha aesthetic)
    │   ├── sxhkd/sxhkdrc           # SXHKD keybindings
    │   ├── polybar/                # Polybar config and launch script (auto-adapts battery widget)
    │   │   ├── config.ini
    │   │   └── launch.sh
    │   ├── picom/picom.conf        # Dual-GPU tear-free GLX picom configuration
    │   ├── rofi/config.rasi        # Modern minimal Rofi launcher theme
    │   ├── kitty/kitty.conf        # Kitty terminal configuration
    │   ├── alacritty/alacritty.toml# Alacritty configuration
    │   └── xinitrc                 # Fallback xinit script
    ├── power/
    │   └── tlp.conf                # TLP profile template
    └── zram/
        └── zram-generator.conf     # zram-generator configuration template
```

---

## 3. Storage & Btrfs Strategy

### Btrfs Multi-Device Modes (`BTRFS_MODE` in `config.env`)

1. **`raid0` (Default - Recommended for Performance):**
   - Data is striped across both 120 GB SSDs (`-d raid0`), providing ~240 GB total capacity and doubled sequential throughput.
   - Metadata is mirrored across both SSDs (`-m raid1`) to prevent filesystem corruption if one device has a bad sector.
2. **`single` (Linear Spanning):**
   - Spans both SSDs sequentially without striping (`-d single -m single`).
3. **`separate` (Isolated Drives):**
   - Drive 1 contains the root Btrfs filesystem (`@`, `@home`, etc.).
   - Drive 2 is formatted independently and mounted at `/data`.

### Btrfs Subvolume Layout
All subvolumes are mounted using:
`noatime,compress=zstd:3,space_cache=v2,discard=async`

- `/` -> `@`
- `/home` -> `@home`
- `/.snapshots` -> `@snapshots`
- `/var/log` -> `@var_log`
- `/var/cache/pacman/pkg` -> `@pkg`
- `/boot` -> 1 GiB FAT32 EFI System Partition (`/dev/sda1`)

---

## 4. Graphics & Thermal Architecture

### AMD Radeon R5 M330 (Oland) on `amdgpu`
The Oland chip (GCN 1.0 / Southern Islands) uses the legacy `radeon` module by default in the Linux kernel. To enable Vulkan (RADV) and modern DRI PRIME render offloading, the installer passes:
```text
radeon.si_support=0 radeon.cik_support=0 amdgpu.si_support=1 amdgpu.cik_support=1
```
In `mkinitcpio.conf`, early KMS is explicitly set to:
```text
MODULES=(i915 amdgpu)
```
Loading `i915` first guarantees that the internal laptop display connected to the Intel UHD 620 initializes as the primary display controller before the discrete Radeon GPU initializes.

### PRIME Render Offloading
Applications run by default on the power-efficient Intel UHD 620. To offload graphics-heavy applications or 3D games to the Radeon R5 M330, use the installed `prime-run` wrapper:
```bash
prime-run <command>
# Examples:
prime-run glxinfo -B
prime-run vkcube
prime-run steam
```

### Thermal & Power Tuning (Intel Core i5-8250U)
The 8th Gen i5-8250U easily thermal-throttles under sustained loads. The deployed TLP profile (`/etc/tlp.d/00-i5-8250u-throttling.conf`) and `thermald`:
- Uses the `powersave` governor with Intel Speed Shift (HWP).
- Sets `balance_performance` on AC and `balance_power` on battery.
- Enables Turbo Boost on AC while capping peak frequency ceiling on battery.
- Enables PCIe ASPM and allows the AMD Radeon dGPU to enter dynamic runtime sleep when not offloading via `prime-run`.

---

## 5. Step-by-Step Installation Guide

### Step 1: Boot the Arch Linux Live ISO
1. Boot the target laptop using the official Arch Linux Live ISO in **UEFI mode**.
2. Connect to the internet:
   - For Ethernet: DHCP will configure automatically.
   - For Wi-Fi: Run `iwctl` to connect to your network:
     ```bash
     iwctl
     station wlan0 scan
     station wlan0 get-networks
     station wlan0 connect "SSID"
     exit
     ```
3. Verify internet connectivity:
   ```bash
   ping -c 2 archlinux.org
   ```

### Step 2: Clone or Download the Setup Scripts
```bash
git clone https://github.com/your-repo/ArchSetup.git
cd ArchSetup
```
*(Or copy the `ArchSetup` folder onto the live environment).*

### Step 3: Customize Configuration
Open [`config.env`](config.env) and adjust the parameters to your preference:
```bash
nano config.env
```
Key parameters to verify:
- `DISK1` and `DISK2` (e.g., `/dev/sda` and `/dev/sdb`).
- `BTRFS_MODE` (`raid0`, `single`, or `separate`).
- `WM` (`bspwm`).
- `DISPLAY_MANAGER` (`sddm` or `none`).
- `TERMINAL` (`kitty` or `alacritty`).
- `USERNAME` (administrative user).
- `TIMEZONE` and `LOCALE`.

### Step 4: Validate / Test (Optional Dry-Run)
Before executing destructive disk operations, you can run a full non-destructive dry-run simulation or the automated test suite:
```bash
# Run installer simulation (dry-run without modifying disks)
./install.sh --dry-run

# Run full test suite (syntax, AST, TOML, INI, permissions & mock staging)
python3 tests/test_archsetup.py
```

### Step 5: Run the Installation
Make scripts executable (if not already):
```bash
chmod +x install.sh stage1_disk_base.sh stage2_chroot.sh
```

Run the master installer:
```bash
./install.sh
```
The script will perform pre-flight checks, display the hardware and disk configuration summary, and prompt for confirmation (`YES`) before partitioning or formatting any drives.

Alternatively, you can run Stage 1 and Stage 2 independently:
```bash
# Execute Stage 1
./stage1_disk_base.sh

# Enter chroot and execute Stage 2
arch-chroot /mnt /opt/arch_installer/stage2_chroot.sh
```

### Step 6: Reboot into the New System
Once the script prints completion:
```bash
umount -R /mnt
reboot
```
Remove the live USB drive when prompted.

---

## 6. Post-Installation Verification

### 1. Verify Btrfs Subvolumes & Multi-Device Pool
```bash
# Check filesystem allocation and devices
btrfs filesystem show /

# Check subvolumes mounted
findmnt -t btrfs
```

### 2. Verify Hybrid Graphics (Intel iGPU + AMD dGPU)
```bash
# Verify Intel UHD 620 is active by default:
glxinfo -B | grep "OpenGL renderer"

# Verify AMD Radeon R5 M330 offloading with prime-run:
prime-run glxinfo -B | grep "OpenGL renderer"

# Verify Vulkan runtimes:
vulkaninfo --summary
prime-run vulkaninfo --summary
```

### 3. Verify ZRAM Configuration
```bash
zramctl
# Expected output: /dev/zram0, zstd algorithm, ~8 GB disksize (50% of 16GB)
```

### 4. Verify Power Management & Thermals
```bash
# Verify TLP status and CPU governor
sudo tlp-stat -p

# Verify thermald is running
systemctl status thermald
```

### 5. Snapshot Booting with `grub-btrfs`
Whenever a snapshot of the `@` subvolume is created into `/.snapshots/` (e.g. via `snapper` or `btrfs subvolume snapshot`), `grub-btrfsd.service` automatically regenerates `/boot/grub/grub.cfg`, allowing you to boot directly into previous snapshots from the GRUB menu.

---

## 7. Keybindings Quick Reference

### BSPWM (`sxhkd`)
- `Super + Return`: Launch terminal (`kitty` / `alacritty`)
- `Super + d`: Application launcher (`rofi` drun mode)
- `Super + r`: Command runner (`rofi` run mode)
- `Super + q`: Close focused window
- `Super + t`: Set window state to tiled
- `Super + Shift + Space`: Toggle floating window
- `Super + f`: Toggle fullscreen
- `Super + h/j/k/l` or `Super + Arrow`: Move focus (West / South / North / East)
- `Super + Shift + h/j/k/l` or `Super + Shift + Arrow`: Swap windows
- `Super + 1-6`: Switch to desktop 1-6
- `Super + Shift + 1-6`: Move window to desktop 1-6
- `Super + Ctrl + h/j/k/l`: Preselect split direction
- `Super + Ctrl + Space`: Cancel preselection
- `Super + Ctrl + r`: Restart BSPWM and reload SXHKD
- `Super + Ctrl + q`: Quit BSPWM session
- `XF86AudioRaiseVolume / LowerVolume / Mute`: Audio volume controls (WirePlumber / PipeWire)
- `XF86MonBrightnessUp / Down`: Display brightness controls (`brightnessctl`)
