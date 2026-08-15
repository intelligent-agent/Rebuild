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

function custom_kernel_config__use_simpledrm_for_panel() {
    echo "🍰Hand the u-boot framebuffer over to simpledrm instead of sun4i-drm"
    # sun8i-dw-hdmi misreads HPD as low for ~570ms while its PHY comes up. The
    # panel never deasserts HPD - it is a false reading - but DRM builds the
    # fbdev console inside that window, gets no EDID, and drm_add_modes_noedid()
    # invents a 1024x768 mode. drm_fb_helper allocates the framebuffer once and
    # cannot grow it afterwards, so that guess is permanent: the panel cannot
    # lock, drops sync and blanks its own backlight.
    #
    # u-boot already reads the EDID and programs the correct mode, and hands the
    # live framebuffer over via /chosen/framebuffer-hdmi. Letting simpledrm adopt
    # it gives the panel's native resolution and a seamless u-boot -> plymouth ->
    # KlipperScreen chain with no mode change anywhere.
    #
    # sun4i-drm has to go entirely rather than merely losing the race: the two
    # cannot coexist, because sun4i-drm reprograms the very mixer/TCON that is
    # scanning out u-boot's framebuffer. Link order was tried and is not enough -
    # it binds through the component framework, so it completes long after its
    # own initcall regardless of where it sits in the link.
    #
    # The trade is no KMS and no runtime hotplug: the mode is whatever u-boot
    # set at boot. A different panel present at boot still works, since u-boot
    # reads its EDID; one plugged in later will not be picked up.
    #
    # Note the connector is renamed by this: simpledrm reports
    # DRM_MODE_CONNECTOR_Unknown, so it is Unknown-1 to the kernel and None-1 to
    # Xorg, not HDMI-A-1/HDMI-1. Anything matching on the connector name has to
    # know both - see rotate-screen in Reflash.
    #
    # Same re-entrancy/hash rule as the hook above.
    if [[ -f .config ]]; then
        kernel_config_set_y "CONFIG_DRM_SIMPLEDRM"
        kernel_config_set_n "CONFIG_DRM_SUN4I"
    else
        kernel_config_modifying_hashes+=("CONFIG_DRM_SIMPLEDRM=y" "CONFIG_DRM_SUN4I=n")
    fi
}

function format_partitions__make_boot_ro() {
    echo "🍰Making boot partition ro"
    sed -i -E 's:/boot ext4 defaults,commit=[0-9]+,errors=remount-ro:/boot ext4 ro,defaults:' $SDCARD/etc/fstab
}

