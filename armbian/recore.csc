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

function post_family_config__shrink_atf() {
    echo "🍰Disable Crust"
    declare -g ATF_TARGET_MAP="PLAT=$ATF_PLAT DEBUG=0 SUNXI_PSCI_USE_SCPI=0 SUNXI_BL31_IN_DRAM=1 SEPARATE_NOBITS_REGION=0 bl31;;build/$ATF_PLAT/release/bl31.bin"

    echo "🍰Compile without SCP binary"
    UBOOT_TARGET_MAP="SCP=/dev/null;;u-boot-sunxi-with-spl.bin"
}

function format_partitions__make_boot_ro() {
    echo "🍰Making boot partition ro"
    sed -i 's:/boot ext4 defaults,commit=600,errors=remount-ro:/boot ext4 ro,defaults:' $SDCARD/etc/fstab
}

#function extension_finish_config__enable_plymouth() {
#    echo "🍰Enable Plymouth on minimal build"
#    PLYMOUTH=yes
#}

