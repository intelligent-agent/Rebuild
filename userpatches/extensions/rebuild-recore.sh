#!/bin/bash
# Rebuild's own build settings for the Recore board, kept out of the board
# config so Armbian's recore.csc is used as it is.

function post_family_config__rebuild_pin_kernel() {
    display_alert "Pin the kernel to a known-good point release" "rebuild" "info"
    declare -g KERNEL_MAJOR_MINOR="6.18"
    declare -g KERNELPATCHDIR="archive/sunxi-6.18"
    declare -g KERNELBRANCH="tag:v6.18.50"
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
