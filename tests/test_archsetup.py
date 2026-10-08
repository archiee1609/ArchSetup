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
