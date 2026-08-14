# Allwinner A64 quad core 1GB RAM SoC GBE for 3D printers
BOARD_NAME="Recore"
BOARD_VENDOR="Iagent"
BOARDFAMILY="sun50iw1"
BOOTCONFIG="recore_defconfig"
KERNEL_TARGET="edge"
KERNEL_TEST_TARGET="edge"
#MODULES="g_serial"
BOOT_LOGO="yes"
WIREGUARD=no
BOOTFS_TYPE=ext4
ATF_SKIP_LDFLAGS_WL=no
INCLUDE_HOME_DIR="yes"

function post_family_config__pin_kernel() {
    echo "🍰Freeze kernel to a known-good point release for reproducible builds"
    declare -g KERNEL_MAJOR_MINOR="6.18"
    declare -g KERNELPATCHDIR="archive/sunxi-6.18"
    declare -g KERNELBRANCH="tag:v6.18.33"
}

function post_family_config__shrink_atf() {
    echo "🍰Disable Crust"
    declare -g ATF_TARGET_MAP="PLAT=$ATF_PLAT DEBUG=0 SUNXI_PSCI_USE_SCPI=0 SUNXI_BL31_IN_DRAM=1 SEPARATE_NOBITS_REGION=0 bl31;;build/$ATF_PLAT/release/bl31.bin"

    echo "🍰Compile without SCP binary"
    UBOOT_TARGET_MAP="SCP=/dev/null;;u-boot-sunxi-with-spl.bin"
}

function custom_kernel_config__enable_fbcon_rotation() {
    echo "🍰Enable framebuffer console rotation"
    # CONFIG_FRAMEBUFFER_CONSOLE_ROTATION is set in linux-sunxi64-legacy.config
    # but is absent from the current/edge configs, so it falls back to the
    # Kconfig default of n. Without it the kernel silently ignores
    # fbcon=rotate:, which rotate-screen writes on every flash - so the text
    # console came up unrotated on a panel that is mounted rotated.
    #
    # The hook can be called more than once and not always with a .config in
    # place; either way it has to contribute to the config hash, or the kernel
    # cache key stops matching the config actually built.
    if [[ -f .config ]]; then
        kernel_config_set_y "CONFIG_FRAMEBUFFER_CONSOLE_ROTATION"
    else
        kernel_config_modifying_hashes+=("CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y")
    fi
}

function format_partitions__make_boot_ro() {
    echo "🍰Making boot partition ro"
    sed -i -E 's:/boot ext4 defaults,commit=[0-9]+,errors=remount-ro:/boot ext4 ro,defaults:' $SDCARD/etc/fstab
}

