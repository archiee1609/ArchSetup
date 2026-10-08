# Adaptive & Modular Arch Linux Deployment Suite
### Hardware-Aware Automated Installer & Tuned Tiling Environment

This repository provides an automated, modular, and robust installation suite for Arch Linux. Equipped with an **intelligent hardware specification recognition engine**, the installer automatically probes system specifications (CPU architecture, RAM, storage topology, GPU architecture, chassis type, and virtualization) before installation begins, dynamically adapting drivers, microcode, kernel parameters, initramfs hooks, filesystem layout, and power profiles to match the host machine.

Originally tailored for an Intel Core i5-8250U + AMD Radeon R5 M330 dual-SSD laptop, the suite has been expanded into a **universal, hardware-aware deployment framework** that works seamlessly across bare-metal laptops, desktops, and virtual machines.

---

## 1. Automatic Hardware Specification Recognition

Before performing any destructive disk operations, the installer executes a comprehensive hardware probe ([`lib/detect.sh`](lib/detect.sh)) and displays a detailed pre-flight profiling report:

| Hardware Domain | Auto-Detection Mechanism | Adaptive Configuration Strategy |
| :--- | :--- | :--- |
| **Platform & Chassis** | `systemd-detect-virt`, DMI `/sys/class/dmi/id/sys_vendor`, `/sys/class/power_supply/BAT*` | **Bare-Metal Laptop**: Enables `tlp`, `powertop`, `brightnessctl`, and `thermald` (Intel-only). Connects battery monitor.<br>**Bare-Metal Desktop**: Configures standard AC performance profile, disables battery throttling.<br>**Virtual Machine**: Disables laptop power/thermal daemons; automatically activates hypervisor guest services. |
| **CPU Architecture** | `/proc/cpuinfo` vendor ID & `lscpu` model string | **Intel**: Installs `intel-ucode`, configures `intel_pstate` governor (`powersave`).<br>**AMD**: Installs `amd-ucode`, configures `amd_pstate` governor. |
| **RAM & ZRAM** | `/proc/meminfo` capacity reading | **$\le$ 4 GB RAM**: Allocates 100% ZRAM with `zstd` compression to prevent out-of-memory lockups.<br>**> 4 GB RAM**: Allocates 50% RAM with `zstd` compression (`zram-generator`). |
| **Storage & Disks** | `lsblk` enumeration (excludes live USB installer media, loops, and RAM disks) | **Single-Disk**: 1 GB EFI partition (`vfat` -> `/boot`) + Btrfs root subvolumes (`@`, `@home`, etc.).<br>**Multi-Disk (2+ Drives)**: Automated striped pool (`raid0`), linear span (`single`), or separate `/data` drive.<br>**Media Adaptation**: Enables `discard=async` for SSDs/NVMe; automatically omits discard on rotational HDDs. |
| **GPU & Graphics** | PCI display devices scanned via `lspci` (`0300`, `0302`, `0380`) | **Intel iGPU**: `mesa`, `vulkan-intel`, `intel-media-driver`, Early KMS `i915`.<br>**AMD APU/dGPU**: `vulkan-radeon`, `amdgpu`. Legacy GCN 1.0/2.0 cards automatically receive SI/CIK flags.<br>**NVIDIA**: `nvidia-dkms`, `nvidia-utils`, Early KMS `nvidia`, `nvidia_drm.modeset=1`.<br>**Hybrid GPUs**: Deploys tailored `/usr/local/bin/prime-run` wrapper (AMD `DRI_PRIME=1` or NVIDIA offload).<br>**VMs**: Installs `virtualbox-guest-utils`, `open-vm-tools`, or `qemu-guest-agent`. |
| **Status Bar (Polybar)** | Verifies `/sys/class/power_supply/` | Adapts battery widget to actual battery name (`BAT0`/`BAT1`) and AC adapter (`AC`/`ADP1`). Cleanly strips battery module on desktops and VMs. |
| **Display & Desktop Stack** | Configuration & Provisioning Engine | **Display Manager**: `lightdm` + `lightdm-gtk-greeter` (configured to launch `bspwm`).<br>**Default Software Stack**: Firefox browser, VLC media player, Neovim (CLI) & Mousepad (GUI), Google Antigravity CLI (`antigravity-cli`). |

---

## 2. Repository Layout

```
ArchSetup/
├── config.env                      # Centralized variables, overrides & user credentials
├── config.env.example              # Reference template with auto-detection options
├── install.sh                      # Master interactive installer with hardware auto-detection
├── stage1_disk_base.sh             # Stage 1: Hardware-aware partitioning, Btrfs setup & pacstrap
├── stage2_chroot.sh                # Stage 2: Tailored drivers, KMS, GRUB, services & dotfiles
├── lib/
│   ├── common.sh                   # Shared logging, UEFI checks, block device helpers
│   └── detect.sh                   # Hardware auto-detection & specification recognition engine
├── configs/
│   ├── amdgpu/
│   │   └── prime-run               # Base DRI_PRIME execution wrapper
│   ├── boot/
│   │   ├── grub.default            # GRUB template config
│   │   └── mkinitcpio.conf         # Initramfs template with Btrfs & KMS hooks
│   ├── dotfiles/
│   │   ├── bspwm/bspwmrc           # BSPWM configuration script (Catppuccin Mocha aesthetic)
│   │   ├── sxhkd/sxhkdrc           # SXHKD keybindings
│   │   ├── polybar/                # Polybar config and launch script (auto-adapts battery module)
│   │   │   ├── config.ini
│   │   │   └── launch.sh
│   │   ├── picom/picom.conf        # Tear-free GLX picom compositor configuration
│   │   ├── rofi/config.rasi        # Modern minimal Rofi launcher theme
│   │   ├── kitty/kitty.conf        # Kitty terminal configuration
│   │   ├── alacritty/alacritty.toml# Alacritty configuration
│   │   └── xinitrc                 # Fallback xinit script
│   ├── power/
│   │   └── tlp.conf                # TLP profile template
│   └── zram/
│       └── zram-generator.conf     # zram-generator configuration template
└── tests/
    ├── test_common.sh              # Unit tests for common library, hardware detection & config
    └── test_archsetup.py           # Test suite (AST, syntax, TOML, INI, KMS, mock staging)
```

---

## 3. Storage & Btrfs Strategy

The filesystem architecture adapts automatically depending on the number of storage devices detected:

### Supported Storage Modes (`BTRFS_MODE`)

1. **`single_disk` (Automatic for Single-Drive Systems):**
   - Automatically selected when 1 usable disk is detected (e.g. `/dev/nvme0n1` or `/dev/sda`).
   - Partition 1: 1 GiB FAT32 EFI System Partition (`/boot`).
   - Partition 2: Remainder formatted with Btrfs (`ARCH_ROOT`) housing all subvolumes.
2. **`raid0` (Multi-Device Performance Striping):**
   - Automatically recommended when 2 or more SSDs are present.
   - Data is striped across both SSDs (`-d raid0`), doubling sequential read/write throughput.
   - Metadata is mirrored (`-m raid1`) for fault tolerance against bad sectors.
3. **`single` (Linear Spanning):**
   - Spans 2 or more drives sequentially without striping (`-d single -m single`), ideal for drives of mismatched sizes or HDDs.
4. **`separate` (Isolated Drives):**
   - Drive 1 contains the root Btrfs filesystem (`@`, `@home`, etc.).
   - Drive 2 is formatted independently and mounted at `/data`.

### Btrfs Subvolume Layout
All subvolumes are mounted using high-performance, resilient options:
`noatime,compress=zstd:3,space_cache=v2[,discard=async]`

- `/` -> `@`
- `/home` -> `@home`
- `/.snapshots` -> `@snapshots`
- `/var/log` -> `@var_log`
- `/var/cache/pacman/pkg` -> `@pkg`
- `/boot` -> 1 GiB FAT32 EFI System Partition (`ef00`)

> [!NOTE]
> `discard=async` is enabled for SSD and NVMe drives to sustain write performance, but is automatically omitted on rotational HDDs where async TRIM is unsupported.

---

## 4. Graphics, Display & Thermal Architecture

### Multi-GPU & Driver Stack
- **Intel iGPU**: Installed with `mesa`, `vulkan-intel`, `intel-media-driver` (modern VA-API), and early KMS `i915`.
- **AMD Radeon / APU**:
  - Modern AMD (GCN 3+, Polaris, Vega, RDNA 1/2/3/4): Driven natively by `amdgpu` and `vulkan-radeon`.
  - Legacy GCN 1.0 / 2.0 (Southern Islands & Sea Islands, e.g. Radeon R5 M330, HD 7000/8000): Automatically configured with kernel parameters `radeon.si_support=0 amdgpu.si_support=1` to enable modern Vulkan (RADV) and PRIME offloading.
- **NVIDIA GPU**: Installed with `nvidia-dkms`, `nvidia-utils`, `lib32-nvidia-utils`, early KMS `nvidia nvidia_modeset nvidia_uvm nvidia_drm`, and `nvidia_drm.modeset=1`.
- **Virtual Machines**: VirtualBox (`virtualbox-guest-utils`), VMware (`open-vm-tools`), or QEMU/KVM (`qemu-guest-agent`).

### PRIME Render Offloading
The `/usr/local/bin/prime-run` execution wrapper is automatically tailored to your GPU topology:
- **AMD Hybrid**: Runs with `DRI_PRIME=1`.
- **NVIDIA Hybrid**: Runs with `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only`.
- **Single GPU**: Functions as a transparent passthrough wrapper.

```bash
prime-run <command>
# Examples:
prime-run glxinfo -B
prime-run vkcube
prime-run steam
```

### Power & Thermal Management
- **Physical Laptops**:
  - TLP profile with frequency ceilings on battery to reduce aggressive thermal throttling.
  - `thermald` deployed on Intel CPUs to manage thermal limits in firmware.
  - `brightnessctl` and `powertop` installed for display and battery tuning.
- **Physical Desktops**:
  - TLP configured with desktop governor profiles without battery throttling.
- **Virtual Machines**:
  - Laptop power and thermal daemons are bypassed, enabling native hypervisor guest daemons instead.

---

## 5. Package Management, Chaotic-AUR & Paru

The installer automates modern repository enhancements and AUR tooling:

### 1. Multilib Repository
- Enables the official `[multilib]` repository in `/etc/pacman.conf` to provide 32-bit libraries required for Steam, Wine, gaming runtimes, and 32-bit graphics acceleration drivers (`lib32-mesa`, `lib32-vulkan-*`).

### 2. Chaotic-AUR Automated Integration
- Automatically imports and signs the Chaotic-AUR primary signing key (`3056513887B78AEB`).
- Installs `chaotic-keyring` and `chaotic-mirrorlist`.
- Configures `[chaotic-aur]` in `/etc/pacman.conf`.
- **Benefit**: Provides direct access to thousands of pre-compiled AUR packages (binaries), drastically speeding up installations without needing to compile large packages from source (e.g. kernels, browsers, utilities).

### 3. Paru AUR Helper
- Installs **`paru`** out of the box via Chaotic-AUR binary packages (with a fallback build via non-root `makepkg` if offline).
- Seamless pacman wrapper with interactive package selection, AUR updates, and syntax highlighting.
```bash
# Search and install any official or AUR package:
paru <package_name>

# Perform full system upgrade (including AUR packages):
paru -Syu
```

### 4. Default Software Stack
The installer equips the system with an idiomatic, curated software stack ready on first boot:
1. **Web Browser (`firefox`)**: Up-to-date Firefox browser with hardware-accelerated rendering.
2. **Developer Agent Orchestration (`antigravity-cli`)**: TUI orchestration tool for Google Antigravity, installed directly via Chaotic-AUR or built via Paru / AUR fallback. Available via `antigravity-cli` or `agy`.
3. **Text Editors (`neovim` & `mousepad`)**:
   - **CLI**: `neovim` configured as the system default (`$EDITOR` and `$VISUAL` in `/etc/profile.d/editor.sh`), along with base `nano` and `vim`.
   - **GUI**: `mousepad`, a lightweight GTK text editor cleanly integrated with BSPWM.
4. **Display Manager (`lightdm` + `lightdm-gtk-greeter`)**:
   - Replaces SDDM with a lightweight, dependable display manager and clean GTK greeter.
   - Pre-configured with session autodetect pointing directly to `bspwm`.
5. **Media Player (`vlc`)**: Full-featured media player with comprehensive codec support out of the box.

---

## 6. Step-by-Step Installation Guide

### Step 1: Boot the Arch Linux Live ISO
1. Boot the target machine using the official Arch Linux Live ISO in **UEFI mode**.
2. Connect to the network:
   - For Ethernet: DHCP configures automatically.
   - For Wi-Fi: Run `iwctl` to connect:
     ```bash
     iwctl station wlan0 connect "SSID"
     ```
3. Verify internet connectivity:
   ```bash
   ping -c 2 archlinux.org
   ```

### Step 2: Clone the Installer
```bash
git clone https://github.com/your-repo/ArchSetup.git
cd ArchSetup
```

### Step 3: Optional Configuration Overrides
The installer automatically recognizes your hardware specifications (`AUTO_DETECT_HARDWARE="true"`). If you wish to set custom passwords, change the username, or override detected defaults, edit [`config.env`](config.env):
```bash
nano config.env
```
Key configurable parameters:
- `USERNAME` (default: `archie`)
- `TIMEZONE` (default: `UTC`)
- `LOCALE` (default: `en_US.UTF-8`)
- `ENABLE_MULTILIB` (default: `true`)
- `ENABLE_CHAOTIC_AUR` (default: `true`)
- `INSTALL_PARU` (default: `true`)
- `WM` (default: `bspwm`)
- `TERMINAL` (`kitty` or `alacritty`)
- `DISPLAY_MANAGER` (`lightdm` or `none`)
- `TEXT_EDITOR` (default: `neovim`)
- `INSTALL_ANTIGRAVITY_CLI` (default: `true`)
- `DISK1` / `DISK2` / `BTRFS_MODE` (only needed if overriding auto-detection)

### Step 4: Validate with Dry-Run Simulation (Recommended)
Before executing destructive disk operations, run the simulation and automated test suite:
```bash
# Execute safe simulation (probes hardware, validates commands without modifying disks)
./install.sh --dry-run

# Run full test suite (syntax, AST, TOML, INI, permissions & mock staging)
python3 tests/test_archsetup.py
./tests/test_common.sh
```

### Step 5: Run the Installation
Make scripts executable:
```bash
chmod +x install.sh stage1_disk_base.sh stage2_chroot.sh lib/detect.sh
```

Run the master installer:
```bash
./install.sh
```

The installer will probe your hardware, present the auto-detected hardware profile summary, and ask for confirmation (`YES`) before partitioning any drives:

```text
======================================================================
         AUTOMATIC HARDWARE SPECIFICATION DISCOVERY & PROFILING       
======================================================================
  Platform / Chassis:     Laptop (Battery: Present [BAT0])
  Processor (CPU):        Intel(R) Core(TM) i5-8250U (8 threads, Vendor: Intel)
  Microcode Package:      intel-ucode
  Physical Memory (RAM):  16.0 GB (16120 MB)
  ZRAM Swap Strategy:     50% RAM (zstd)
  Detected Disks:         2 usable drive(s) found
    * /dev/sda [120G, sata, SSD KINGSTON SA400S37120G]
    * /dev/sdb [120G, sata, SSD Crucial CT120BX500SSD1]
  Primary Target Disk:    /dev/sda
  Secondary Disk:         /dev/sdb
  Btrfs Pool Strategy:    raid0
  Mount Options:          noatime,compress=zstd:3,space_cache=v2,discard=async
  Graphics Architecture:  intel-amd-hybrid
  Early KMS Modules:      i915 amdgpu
  PRIME Offloading:       amd
  Multilib Repository:    Enabled
  Chaotic-AUR:            Enabled
  AUR Helper:             paru
  Power & Thermal Plan:   TLP (intel_pstate) + thermald thermal mitigation
======================================================================
```

Type `YES` to proceed. The script will execute Stage 1 (partitioning, Btrfs, and pacstrap) followed by Stage 2 in chroot.

### Step 6: Reboot into the New System
When installation finishes:
```bash
umount -R /mnt
reboot
```
Remove your live USB installer when prompted.

---

## 7. Post-Installation Verification

### 1. Verify Btrfs Subvolumes & Storage Layout
```bash
# Check filesystem allocation and devices
btrfs filesystem show /

# Check mounted subvolumes
findmnt -t btrfs
```

### 2. Verify Graphics & PRIME Offloading
```bash
# Verify default display renderer:
glxinfo -B | grep "OpenGL renderer"

# Verify discrete GPU offloading (on dual-GPU systems):
prime-run glxinfo -B | grep "OpenGL renderer"

# Verify Vulkan runtimes:
vulkaninfo --summary
```

### 3. Verify ZRAM Configuration
```bash
zramctl
# Expected: /dev/zram0, zstd compression, auto-sized swap capacity
```

### 4. Verify Power Management & Thermals
```bash
# Check TLP status and active governor
sudo tlp-stat -p

# Check thermald status (Intel laptops)
systemctl status thermald
```

### 5. Verify Multilib & Chaotic-AUR Repositories
```bash
# Verify multilib packages are available:
pacman -Sl multilib | head -n 5

# Verify Chaotic-AUR binary packages are available:
pacman -Sl chaotic-aur | head -n 5
```

### 6. Verify Paru AUR Helper
```bash
# Verify paru is functional:
paru --version
paru -Syu
```

### 7. Snapshot Booting with `grub-btrfs`
Whenever a snapshot of the `@` subvolume is created in `/.snapshots/` (e.g. via `snapper` or `btrfs subvolume snapshot`), `grub-btrfsd.service` automatically regenerates `/boot/grub/grub.cfg`, allowing you to boot directly into previous system snapshots from the GRUB boot menu.

### 8. Verify Display Manager (LightDM)
```bash
# Check LightDM display manager service status:
systemctl status lightdm.service

# Verify GTK greeter and BSPWM session configuration:
grep -E "greeter-session|user-session" /etc/lightdm/lightdm.conf
cat /usr/share/xsessions/bspwm.desktop
```

### 9. Verify Default Software Applications
```bash
# Verify Firefox browser:
firefox --version

# Verify VLC media player:
vlc --version

# Verify Neovim and Mousepad text editors:
nvim --version
mousepad --version
echo "System Editor: $EDITOR | Visual Editor: $VISUAL"

# Verify Antigravity CLI agent orchestration tool:
antigravity-cli --version || agy --version
```

---

## 8. Keybindings Quick Reference

### BSPWM (`sxhkd`)
- `Super + Return`: Launch terminal (`kitty` / `alacritty`)
- `Super + d`: Application launcher (`rofi` drun mode — launch Firefox, VLC, Mousepad, etc.)
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

### Default Applications Quick Launch
| Application | Launch Command | GUI Shortcut | Purpose |
| :--- | :--- | :--- | :--- |
| **Firefox** | `firefox &` | `Super + d` -> type `firefox` | Web Browsing |
| **VLC Media Player** | `vlc &` | `Super + d` -> type `vlc` | Media Playback |
| **Mousepad** | `mousepad &` | `Super + d` -> type `mousepad` | Lightweight GTK GUI Text Editor |
| **Neovim** | `nvim <file>` | Terminal (`Super + Return`) | Primary Terminal Text Editor |
| **Antigravity CLI** | `antigravity-cli` or `agy` | Terminal (`Super + Return`) | Agentic AI Orchestration TUI |
| **Paru** | `paru <pkg>` | Terminal (`Super + Return`) | AUR Package Helper & Pacman Wrapper |

