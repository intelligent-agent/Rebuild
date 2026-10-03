#!/bin/bash
# Rebuild's own build settings for the Recore board, kept out of the board
# config so Armbian's recore.csc is used as it is.

function post_family_config__rebuild_pin_kernel() {
    display_alert "Pin the kernel to a known-good point release" "rebuild" "info"
    declare -g KERNEL_MAJOR_MINOR="6.18"
    declare -g KERNELPATCHDIR="archive/sunxi-6.18"
    declare -g KERNELBRANCH="tag:v6.18.54"
}

function format_partitions__rebuild_boot_ro() {
    display_alert "Make the boot partition read-only" "rebuild" "info"
    sed -i -E 's:/boot ext4 defaults,commit=[0-9]+,errors=remount-ro:/boot ext4 ro,defaults:' $SDCARD/etc/fstab
}

function post_family_config__rebuild_no_g_serial() {
    display_alert "Leave the USB-C gadget to Rebuild's own configfs setup" "rebuild" "info"
    declare -g MODULES=""
}

function extension_finish_config__rebuild_no_armbian_plymouth() {
    display_alert "Use Rebuild's Plymouth setup, not Armbian's" "rebuild" "info"
    declare -g PLYMOUTH=no
}

function post_family_config__rebuild_boot_partition() {
    display_alert "Separate ext4 /boot partition, as Reflash expects" "rebuild" "info"
    declare -g BOOTFS_TYPE="ext4"
}

# Until armbian/build#10853 is merged, carried here together with the U-Boot and
# TF-A patches in armbian/patch/u-boot/v2026.07-sunxi64/board_recore (copied
# over Armbian's by rebuild.sh) and userpatches/atf/atf-sunxi64/board_recore;
# drop all three then.
#
# Runs after recore.csc's post_family_config__shrink_atf, which still pins
# TF-A v2.8.0 in SRAM.
function post_family_config__900_rebuild_bl31_in_dram() {
    display_alert "Put BL31 in DRAM to free SRAM A2 for the AR100" "rebuild" "info"
    declare -g ATFBRANCH="tag:lts-v2.12.9"
    unset ATF_SKIP_LDFLAGS_WL
    declare -g ATF_TARGET_MAP="PLAT=$ATF_PLAT DEBUG=0 SUNXI_PSCI_USE_SCPI=0 SUNXI_BL31_IN_DRAM=1 SEPARATE_NOBITS_REGION=0 bl31;;build/$ATF_PLAT/release/bl31.bin"
}

# Test variant: build simpledrm as a module and place it in the initramfs.
# This tests whether loading it from initramfs avoids the display handoff loss.
#
# The hook can be called more than once and not always with a .config in place;
# either way it has to contribute to the config hash, or the kernel cache key
# stops matching the config actually built.
function custom_kernel_config__rebuild_simpledrm_and_fbcon_rotation() {
    if [[ -f .config ]]; then
        kernel_config_set_m "CONFIG_DRM_SIMPLEDRM"
        kernel_config_set_y "CONFIG_FRAMEBUFFER_CONSOLE_ROTATION"
    else
        kernel_config_modifying_hashes+=("CONFIG_DRM_SIMPLEDRM=m" "CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y")
    fi
}

# Keep the kernel's last messages across a crash, and catch lockups (#107).
# rebuild-recore reboots the board 10 s after a panic and makes soft and hard
# lockups panic; without these the panic log is gone after the reboot
# (ramoops writes it to the region the Recore device tree reserves at
# 0x6ff00000, read back from /sys/fs/pstore) and a stuck CPU is never noticed.
# The hard lockup detector is the buddy kind: arm64 has no NMI watchdog here.
function custom_kernel_config__rebuild_crash_log_and_lockups() {
    local opt opts=(PSTORE PSTORE_RAM PSTORE_CONSOLE SOFTLOCKUP_DETECTOR
                    HARDLOCKUP_DETECTOR HARDLOCKUP_DETECTOR_BUDDY)
    if [[ -f .config ]]; then
        for opt in "${opts[@]}"; do
            kernel_config_set_y "CONFIG_$opt"
        done
    else
        for opt in "${opts[@]}"; do
            kernel_config_modifying_hashes+=("CONFIG_$opt=y")
        done
    fi
}
