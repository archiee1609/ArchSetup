#!/usr/bin/env python3
"""
Comprehensive Validation & Test Suite for ArchSetup Tool
Tests configuration syntax, script compilation, dotfiles validity,
permissions, and simulates deployment into a mock chroot environment.
"""

import ast
import configparser
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

REPO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

GREEN = "\033[1;32m"
RED = "\033[1;31m"
BLUE = "\033[1;34m"
RESET = "\033[0m"

failed_count = 0
passed_count = 0

def report(name, success, detail=""):
    global failed_count, passed_count
    if success:
        passed_count += 1
        print(f"{GREEN}[PASS]{RESET} {name}")
    else:
        failed_count += 1
        print(f"{RED}[FAIL]{RESET} {name} - {detail}")

def run_tests():
    global failed_count, passed_count
    failed_count = 0
    passed_count = 0

    print(f"{BLUE}======================================================================{RESET}")
    print(f"{BLUE}                ArchSetup Validation & Test Suite                     {RESET}")
    print(f"{BLUE}======================================================================{RESET}")

    # ------------------------------------------------------------------------------
    # 1. Shell Script Syntax Checks (bash -n)
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 1. Testing Bash Scripts Syntax ---{RESET}")
    shell_scripts = [
        "install.sh",
        "stage1_disk_base.sh",
        "stage2_chroot.sh",
        "lib/common.sh",
        "lib/detect.sh",
        "configs/amdgpu/prime-run",
        "configs/dotfiles/bspwm/bspwmrc",
        "configs/dotfiles/polybar/launch.sh",
        "configs/dotfiles/xinitrc",
        "tests/test_common.sh",
    ]

    for script in shell_scripts:
        script_path = os.path.join(REPO_DIR, script)
        if not os.path.exists(script_path):
            report(f"File exists: {script}", False, "File not found")
            continue
        res = subprocess.run(["bash", "-n", script_path], capture_output=True, text=True)
        report(f"Syntax validation: {script}", res.returncode == 0, res.stderr.strip())

    # ------------------------------------------------------------------------------
    # 2. Executable Permissions Check
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 2. Checking Executable File Permissions ---{RESET}")
    executable_targets = [
        "install.sh",
        "stage1_disk_base.sh",
        "stage2_chroot.sh",
        "lib/common.sh",
        "lib/detect.sh",
        "configs/amdgpu/prime-run",
        "configs/dotfiles/bspwm/bspwmrc",
        "configs/dotfiles/polybar/launch.sh",
        "configs/dotfiles/xinitrc",
    ]

    for target in executable_targets:
        target_path = os.path.join(REPO_DIR, target)
        is_exec = os.access(target_path, os.X_OK)
        report(f"Executable bit (+x): {target}", is_exec, "Executable permission missing")

    # ------------------------------------------------------------------------------
    # 3. BSPWM & SXHKD Configuration Validation
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 3. Testing BSPWM & SXHKD Configurations ---{RESET}")
    report("Qtile completely removed from configs", not os.path.exists(os.path.join(REPO_DIR, "configs/dotfiles/qtile")))

    bspwmrc_path = os.path.join(REPO_DIR, "configs/dotfiles/bspwm/bspwmrc")
    try:
        with open(bspwmrc_path, "r", encoding="utf-8") as f:
            bspwmrc_content = f.read()
        report("BSPWM config exists", True)
        report("BSPWM config launches sxhkd", "sxhkd" in bspwmrc_content)
        report("BSPWM config configures monitors", "bspc monitor" in bspwmrc_content)
        report("BSPWM config launches picom", "picom" in bspwmrc_content)
        report("BSPWM config launches polybar", "polybar" in bspwmrc_content)
    except Exception as e:
        report("BSPWM config validation", False, str(e))

    sxhkdrc_path = os.path.join(REPO_DIR, "configs/dotfiles/sxhkd/sxhkdrc")
    try:
        with open(sxhkdrc_path, "r", encoding="utf-8") as f:
            sxhkdrc_content = f.read()
        report("SXHKD config exists", True)
        report("SXHKD config defines terminal shortcut", "super + Return" in sxhkdrc_content)
        report("SXHKD config defines launcher shortcut", "rofi" in sxhkdrc_content)
        report("SXHKD config defines workspace navigation", "bspc desktop -f" in sxhkdrc_content)
        report("SXHKD config defines quit command", "bspc quit" in sxhkdrc_content)
    except Exception as e:
        report("SXHKD config validation", False, str(e))

    # ------------------------------------------------------------------------------
    # 4. Alacritty TOML Configuration Validation
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 4. Testing Alacritty TOML Configuration ---{RESET}")
    alacritty_config_path = os.path.join(REPO_DIR, "configs/dotfiles/alacritty/alacritty.toml")
    try:
        with open(alacritty_config_path, "rb") as f:
            alacritty_data = tomllib.load(f)
        report("Alacritty TOML valid format", True)
        report("Alacritty 'font' table defined", "font" in alacritty_data, "Missing [font]")
        report("Alacritty 'colors' table defined", "colors" in alacritty_data, "Missing [colors]")
        report("Alacritty 'window' table defined", "window" in alacritty_data, "Missing [window]")
    except Exception as e:
        report("Alacritty TOML parsing", False, str(e))

    # ------------------------------------------------------------------------------
    # 5. Polybar & ZRAM INI Validation
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 5. Testing INI Configurations (Polybar & ZRAM) ---{RESET}")
    polybar_config_path = os.path.join(REPO_DIR, "configs/dotfiles/polybar/config.ini")
    try:
        poly_cfg = configparser.ConfigParser()
        poly_cfg.read(polybar_config_path)
        report("Polybar INI valid format", True)
        report("Polybar 'bar/main' defined", poly_cfg.has_section("bar/main"))
        report("Polybar 'module/bspwm' defined", poly_cfg.has_section("module/bspwm"))
        report("Polybar 'module/cpu' defined", poly_cfg.has_section("module/cpu"))
        report("Polybar 'module/memory' defined", poly_cfg.has_section("module/memory"))
        report("Polybar 'module/battery' defined", poly_cfg.has_section("module/battery"))
    except Exception as e:
        report("Polybar INI parsing", False, str(e))

    zram_config_path = os.path.join(REPO_DIR, "configs/zram/zram-generator.conf")
    try:
        zram_cfg = configparser.ConfigParser()
        zram_cfg.read(zram_config_path)
        report("ZRAM INI valid format", True)
        report("ZRAM 'zram0' section defined", zram_cfg.has_section("zram0"))
        size_val = zram_cfg.get("zram0", "zram-size")
        algo_val = zram_cfg.get("zram0", "compression-algorithm")
        report("ZRAM 50% fraction specified", "0.5" in size_val or "ram / 2" in size_val or "ram * 0.5" in size_val, f"Got: {size_val}")
        report("ZRAM compression is zstd", algo_val.strip() == "zstd", f"Got: {algo_val}")
    except Exception as e:
        report("ZRAM INI parsing", False, str(e))

    # ------------------------------------------------------------------------------
    # 6. Picom & Rofi Configuration Syntax Checks
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 6. Testing Picom & Rofi Configurations ---{RESET}")
    picom_path = os.path.join(REPO_DIR, "configs/dotfiles/picom/picom.conf")
    try:
        with open(picom_path, "r", encoding="utf-8") as f:
            picom_text = f.read()
        # Check dual-GPU requirements
        report("Picom GLX backend enabled", 'backend = "glx";' in picom_text)
        report("Picom VSync enabled", "vsync = true;" in picom_text)
        report("Picom glx-no-stencil enabled", "glx-no-stencil = true;" in picom_text)
        report("Picom unredir-if-possible is false", "unredir-if-possible = false;" in picom_text)
        # Check braces balance
        open_braces = picom_text.count("{")
        close_braces = picom_text.count("}")
        report("Picom braces balanced", open_braces == close_braces, f"{{: {open_braces}, }}: {close_braces}")
    except Exception as e:
        report("Picom config check", False, str(e))

    rofi_path = os.path.join(REPO_DIR, "configs/dotfiles/rofi/config.rasi")
    try:
        with open(rofi_path, "r", encoding="utf-8") as f:
            rofi_text = f.read()
        report("Rofi drun mode configured", 'modi: "drun,run,window";' in rofi_text)
        open_braces = rofi_text.count("{")
        close_braces = rofi_text.count("}")
        report("Rofi braces balanced", open_braces == close_braces, f"{{: {open_braces}, }}: {close_braces}")
    except Exception as e:
        report("Rofi config check", False, str(e))

    # ------------------------------------------------------------------------------
    # 7. GRUB Default Kernel Parameters Check
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 7. Testing GRUB Hardware Parameters ---{RESET}")
    grub_path = os.path.join(REPO_DIR, "configs/boot/grub.default")
    try:
        with open(grub_path, "r", encoding="utf-8") as f:
            grub_text = f.read()
        report("GRUB has radeon.si_support=0", "radeon.si_support=0" in grub_text)
        report("GRUB has amdgpu.si_support=1", "amdgpu.si_support=1" in grub_text)
        report("GRUB has radeon.cik_support=0", "radeon.cik_support=0" in grub_text)
        report("GRUB has amdgpu.cik_support=1", "amdgpu.cik_support=1" in grub_text)
        report("GRUB preloads btrfs", "btrfs" in grub_text and "GRUB_PRELOAD_MODULES" in grub_text)
    except Exception as e:
        report("GRUB config check", False, str(e))

    # ------------------------------------------------------------------------------
    # 8. Early KMS Modules Check (mkinitcpio.conf)
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 8. Testing mkinitcpio Early KMS Configuration ---{RESET}")
    mkinitcpio_path = os.path.join(REPO_DIR, "configs/boot/mkinitcpio.conf")
    try:
        with open(mkinitcpio_path, "r", encoding="utf-8") as f:
            mkinit_text = f.read()
        report("Early KMS has i915 amdgpu in correct order", "MODULES=(i915 amdgpu)" in mkinit_text)
        report("mkinitcpio includes btrfs hook", "btrfs" in mkinit_text and "HOOKS=" in mkinit_text)
    except Exception as e:
        report("mkinitcpio config check", False, str(e))

    # ------------------------------------------------------------------------------
    # 9. TLP Power Management Profile Check
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 9. Testing TLP Profile for Intel i5-8250U ---{RESET}")
    tlp_path = os.path.join(REPO_DIR, "configs/power/tlp.conf")
    try:
        with open(tlp_path, "r", encoding="utf-8") as f:
            tlp_text = f.read()
        report("TLP governor is powersave (intel_pstate)", "CPU_SCALING_GOVERNOR_ON_AC=powersave" in tlp_text)
        report("TLP energy-perf policy on AC", "CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance" in tlp_text)
        report("TLP turbo boost enabled on AC", "CPU_BOOST_ON_AC=1" in tlp_text)
        report("TLP turbo boost disabled on battery", "CPU_BOOST_ON_BAT=0" in tlp_text)
        report("TLP battery max perf capped to reduce throttling", "CPU_MAX_PERF_ON_BAT=70" in tlp_text)
        report("TLP runtime PM enabled for dGPU suspend", "RUNTIME_PM_ON_BAT=auto" in tlp_text)
    except Exception as e:
        report("TLP profile check", False, str(e))

    # ------------------------------------------------------------------------------
    # 10. Simulated Mock Deployment & Sed Substitution Test
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 10. Testing Simulated Staging & File Deployment ---{RESET}")
    with tempfile.TemporaryDirectory() as tmpdir:
        mock_mnt = os.path.join(tmpdir, "mock_mnt")
        os.makedirs(mock_mnt)

        # 1. Simulate Stage 1 copy to chroot
        installer_dir = os.path.join(mock_mnt, "opt/arch_installer")
        os.makedirs(installer_dir)
        shutil.copy(os.path.join(REPO_DIR, "config.env"), installer_dir)
        shutil.copytree(os.path.join(REPO_DIR, "lib"), os.path.join(installer_dir, "lib"))
        shutil.copytree(os.path.join(REPO_DIR, "configs"), os.path.join(installer_dir, "configs"))
        shutil.copy(os.path.join(REPO_DIR, "stage2_chroot.sh"), installer_dir)

        report("Stage 1 staging copies to /opt/arch_installer",
               os.path.exists(os.path.join(installer_dir, "stage2_chroot.sh")) and
               os.path.exists(os.path.join(installer_dir, "config.env")))

        # 2. Simulate Stage 2 user dotfiles deployment
        mock_user_home = os.path.join(mock_mnt, "home/testuser")
        mock_user_config = os.path.join(mock_user_home, ".config")
        os.makedirs(os.path.join(mock_user_config, "bspwm"), exist_ok=True)
        os.makedirs(os.path.join(mock_user_config, "sxhkd"), exist_ok=True)
        os.makedirs(os.path.join(mock_user_config, "polybar"), exist_ok=True)
        os.makedirs(os.path.join(mock_user_config, "picom"), exist_ok=True)
        os.makedirs(os.path.join(mock_user_config, "rofi"), exist_ok=True)
        os.makedirs(os.path.join(mock_user_config, "kitty"), exist_ok=True)
        os.makedirs(os.path.join(mock_user_config, "alacritty"), exist_ok=True)

        configs_dir = os.path.join(installer_dir, "configs")
        shutil.copy(os.path.join(configs_dir, "dotfiles/picom/picom.conf"), os.path.join(mock_user_config, "picom/picom.conf"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/rofi/config.rasi"), os.path.join(mock_user_config, "rofi/config.rasi"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/kitty/kitty.conf"), os.path.join(mock_user_config, "kitty/kitty.conf"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/alacritty/alacritty.toml"), os.path.join(mock_user_config, "alacritty/alacritty.toml"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/bspwm/bspwmrc"), os.path.join(mock_user_config, "bspwm/bspwmrc"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/sxhkd/sxhkdrc"), os.path.join(mock_user_config, "sxhkd/sxhkdrc"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/polybar/config.ini"), os.path.join(mock_user_config, "polybar/config.ini"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/polybar/launch.sh"), os.path.join(mock_user_config, "polybar/launch.sh"))
        shutil.copy(os.path.join(configs_dir, "dotfiles/xinitrc"), os.path.join(mock_user_home, ".xinitrc"))

        all_dotfiles_exist = all([
            not os.path.exists(os.path.join(mock_user_config, "qtile")),
            os.path.isfile(os.path.join(mock_user_config, "bspwm/bspwmrc")),
            os.path.isfile(os.path.join(mock_user_config, "sxhkd/sxhkdrc")),
            os.path.isfile(os.path.join(mock_user_config, "polybar/config.ini")),
            os.path.isfile(os.path.join(mock_user_config, "picom/picom.conf")),
            os.path.isfile(os.path.join(mock_user_config, "rofi/config.rasi")),
            os.path.isfile(os.path.join(mock_user_config, "kitty/kitty.conf")),
            os.path.isfile(os.path.join(mock_user_config, "alacritty/alacritty.toml")),
            os.path.isfile(os.path.join(mock_user_home, ".xinitrc")),
        ])
        report("All user dotfiles deployed properly to target paths", all_dotfiles_exist)

        # 3. Simulate sed replacements on mock /etc files
        mock_etc = os.path.join(mock_mnt, "etc")
        os.makedirs(mock_etc)
        
        # Mock /etc/pacman.conf
        with open(os.path.join(mock_etc, "pacman.conf"), "w") as f:
            f.write("#ParallelDownloads = 5\n#Color\n")
        # Mock /etc/locale.gen
        with open(os.path.join(mock_etc, "locale.gen"), "w") as f:
            f.write("#en_US.UTF-8 UTF-8\n")
        # Mock /etc/default/grub
        with open(os.path.join(mock_etc, "grub_default"), "w") as f:
            f.write('GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"\n')

        # Run seds
        subprocess.run(["sed", "-i", "s/^#ParallelDownloads = 5/ParallelDownloads = 5/", os.path.join(mock_etc, "pacman.conf")], check=True)
        subprocess.run(["sed", "-i", "s/^#Color/Color/", os.path.join(mock_etc, "pacman.conf")], check=True)
        subprocess.run(["sed", "-i", "s/^#en_US.UTF-8/en_US.UTF-8/", os.path.join(mock_etc, "locale.gen")], check=True)

        with open(os.path.join(mock_etc, "pacman.conf")) as f:
            p_content = f.read()
        with open(os.path.join(mock_etc, "locale.gen")) as f:
            l_content = f.read()

        report("sed transforms /etc/pacman.conf correctly", "ParallelDownloads = 5" in p_content and "Color" in p_content)
        report("sed uncomments /etc/locale.gen correctly", "en_US.UTF-8 UTF-8" in l_content)

        # Mock multilib and chaotic-aur activation
        with open(os.path.join(mock_etc, "pacman.conf"), "a") as f:
            f.write("\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n")

        with open(os.path.join(mock_etc, "pacman.conf")) as f:
            p_full = f.read()

        report("pacman.conf enables [multilib]", "[multilib]" in p_full)
        report("pacman.conf enables [chaotic-aur]", "[chaotic-aur]" in p_full and "chaotic-mirrorlist" in p_full)

        # 4. Verify default applications and display manager in stage2_chroot.sh
        stage2_path = os.path.join(REPO_DIR, "stage2_chroot.sh")
        with open(stage2_path, "r", encoding="utf-8") as f:
            stage2_content = f.read()

        report("Firefox is included in default packages", "firefox" in stage2_content)
        report("VLC is included in default packages", "vlc" in stage2_content)
        report("Text editor (neovim/mousepad) is included", "neovim" in stage2_content and "mousepad" in stage2_content)
        report("LightDM and GTK greeter replace SDDM", "lightdm" in stage2_content and "lightdm-gtk-greeter" in stage2_content)
        report("LightDM service is enabled", "systemctl enable lightdm.service" in stage2_content)
        report("antigravity-cli installation step present", "antigravity-cli" in stage2_content)

    # ------------------------------------------------------------------------------
    # 11. Testing Hardware Auto-Detection & Specification Recognition
    # ------------------------------------------------------------------------------
    print(f"\n{BLUE}--- 11. Testing Hardware Auto-Detection & Adaptive Profiling ---{RESET}")
    detect_sh_path = os.path.join(REPO_DIR, "lib/detect.sh")

    # 1. Test live hardware detection execution
    detect_res = subprocess.run(
        ["bash", "-c", f"source {detect_sh_path} && detect_hardware && apply_hardware_profile && echo DETECTED_CPU=$DETECTED_CPU_VENDOR && echo DETECTED_RAM=$DETECTED_RAM_MB && echo DETECTED_DISKS=$DETECTED_DISK_COUNT && echo DETECTED_GPU=$DETECTED_GPU_SETUP && echo UCODE=$CPU_UCODE_PACKAGE"],
        capture_output=True, text=True
    )
    report("detect_hardware runs without errors", detect_res.returncode == 0, detect_res.stderr.strip())
    report("Live CPU vendor detected", "DETECTED_CPU=" in detect_res.stdout)
    report("Live RAM MB detected", "DETECTED_RAM=" in detect_res.stdout)
    report("Live Disks counted", "DETECTED_DISKS=" in detect_res.stdout)
    report("Live GPU setup classified", "DETECTED_GPU=" in detect_res.stdout)
    report("CPU microcode resolved", "UCODE=" in detect_res.stdout)

    # 2. Test CPU vendor to microcode package mapping
    test_cpu_intel = subprocess.run(
        ["bash", "-c", f'source {detect_sh_path} && DETECTED_CPU_VENDOR="Intel" && DETECTED_CPU_UCODE="intel-ucode" && apply_hardware_profile && echo $CPU_UCODE_PACKAGE'],
        capture_output=True, text=True
    )
    report("Intel CPU resolves to intel-ucode", test_cpu_intel.stdout.strip() == "intel-ucode", test_cpu_intel.stdout.strip())

    test_cpu_amd = subprocess.run(
        ["bash", "-c", f'source {detect_sh_path} && DETECTED_CPU_VENDOR="AMD" && DETECTED_CPU_UCODE="amd-ucode" && apply_hardware_profile && echo $CPU_UCODE_PACKAGE'],
        capture_output=True, text=True
    )
    report("AMD CPU resolves to amd-ucode", test_cpu_amd.stdout.strip() == "amd-ucode", test_cpu_amd.stdout.strip())

    # 3. Test RAM sizing to ZRAM fraction calculation
    test_ram_low = subprocess.run(
        ["bash", "-c", f'source {detect_sh_path} && detect_ram 3800 && echo $DETECTED_ZRAM_FRACTION'],
        capture_output=True, text=True
    )
    report("RAM <= 4GB allocates 100% ZRAM", test_ram_low.stdout.strip() == "1.0", test_ram_low.stdout.strip())

    test_ram_high = subprocess.run(
        ["bash", "-c", f'source {detect_sh_path} && detect_ram 16384 && echo $DETECTED_ZRAM_FRACTION'],
        capture_output=True, text=True
    )
    report("RAM >= 16GB allocates 50% ZRAM", test_ram_high.stdout.strip() == "0.5", test_ram_high.stdout.strip())

    # 4. Test Single-Disk vs Multi-Disk Btrfs profile adaptation
    test_disk_single = subprocess.run(
        ["bash", "-c", f'source {detect_sh_path} && DETECTED_DISK_COUNT=1 && DETECTED_PRIMARY_DISK="/dev/sda" && DETECTED_PRIMARY_DISK_ROTA=0 && DETECTED_SECONDARY_DISK="" && apply_hardware_profile && echo "$BTRFS_MODE|$DISK1|$DISK2"'],
        capture_output=True, text=True
    )
    report("1 disk automatically selects single_disk mode", test_disk_single.stdout.strip() == "single_disk|/dev/sda|", test_disk_single.stdout.strip())

    test_disk_multi = subprocess.run(
        ["bash", "-c", f'source {detect_sh_path} && DETECTED_DISK_COUNT=2 && DETECTED_PRIMARY_DISK="/dev/sda" && DETECTED_PRIMARY_DISK_ROTA=0 && DETECTED_SECONDARY_DISK="/dev/sdb" && DETECTED_RECOMMENDED_BTRFS_MODE="raid0" && apply_hardware_profile && echo "$BTRFS_MODE|$DISK1|$DISK2"'],
        capture_output=True, text=True
    )
    report("2 SSDs select multi-device RAID0 mode", "raid0|/dev/sda|/dev/sdb" in test_disk_multi.stdout.strip(), test_disk_multi.stdout.strip())

    # 5. Test GPU Early KMS and PRIME resolution
    test_gpu_hybrid = subprocess.run(
        ["bash", "-c", f'''source {detect_sh_path}
mock_gpu="00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics 620 [8086:5917]
01:00.0 Display controller [0380]: Advanced Micro Devices, Inc. Radeon R5 M330 [1002:6900]"
detect_gpus "$mock_gpu"
echo "$DETECTED_GPU_SETUP|$DETECTED_KMS_MODULES|$DETECTED_PRIME_TYPE"
'''],
        capture_output=True, text=True
    )
    report("Intel+AMD SI hybrid sets i915 amdgpu & amd prime", "intel-amd-hybrid|i915 amdgpu|amd" in test_gpu_hybrid.stdout.strip(), test_gpu_hybrid.stdout.strip())

    test_gpu_nvidia = subprocess.run(
        ["bash", "-c", f'''source {detect_sh_path}
mock_gpu="00:02.0 VGA compatible controller [0300]: Intel Corporation UHD [8086:9a60]
01:00.0 3D controller [0302]: NVIDIA Corporation RTX 3060 [10de:2503]"
detect_gpus "$mock_gpu"
echo "$DETECTED_GPU_SETUP|$DETECTED_PRIME_TYPE"
'''],
        capture_output=True, text=True
    )
    report("Intel+NVIDIA sets intel-nvidia-hybrid & nvidia prime", "intel-nvidia-hybrid|nvidia" in test_gpu_nvidia.stdout.strip(), test_gpu_nvidia.stdout.strip())

    # 6. Test Polybar battery adaptation for desktop/VM vs laptop
    with tempfile.NamedTemporaryFile("w+", delete=False) as tf:
        poly_temp_path = tf.name
        tf.write("""[bar/main]
modules-right = cpu memory battery pulseaudio date
[module/battery]
battery = BAT0
adapter = ADP1
""")

    try:
        # Simulate no battery (desktop or VM)
        subprocess.run(["bash", "-c", f'sed -i "s/modules-right = cpu memory battery pulseaudio date/modules-right = cpu memory pulseaudio date/" {poly_temp_path}'], check=True)
        with open(poly_temp_path) as f:
            poly_no_bat = f.read()
        report("Polybar removes battery module when no battery present", "battery pulseaudio" not in poly_no_bat and "pulseaudio date" in poly_no_bat)
    finally:
        if os.path.exists(poly_temp_path):
            os.remove(poly_temp_path)

    # 7. Test save_hardware_profile persistence
    with tempfile.NamedTemporaryFile("w+", delete=False) as tf:
        hw_save_path = tf.name
    try:
        subprocess.run(["bash", "-c", f'source {detect_sh_path} && detect_hardware && apply_hardware_profile && save_hardware_profile "{hw_save_path}"'], check=True)
        with open(hw_save_path) as f:
            hw_content = f.read()
        report("Hardware profile file correctly created", os.path.exists(hw_save_path))
        report("Hardware profile defines DETECTED_CPU_VENDOR", "DETECTED_CPU_VENDOR=" in hw_content)
        report("Hardware profile defines BTRFS_MODE", "BTRFS_MODE=" in hw_content)
        report("Hardware profile defines KMS_MODULES", "KMS_MODULES=" in hw_content)
    finally:
        if os.path.exists(hw_save_path):
            os.remove(hw_save_path)

    print(f"\n{BLUE}======================================================================{RESET}")
    print(f"Test Results: {GREEN}{passed_count} Passed{RESET}, {RED if failed_count else GREEN}{failed_count} Failed{RESET}")
    print(f"{BLUE}======================================================================{RESET}")

    if failed_count == 0:
        print(f"\n{GREEN}All verification checks and mock tests PASSED! Everything is working cleanly.{RESET}\n")
        return 0
    else:
        print(f"\n{RED}Some checks failed! Please review output above.{RESET}\n")
        return 1


class TestArchSetup(unittest.TestCase):
    def test_all_checks(self):
        self.assertEqual(run_tests(), 0)


if __name__ == "__main__":
    sys.exit(run_tests())
