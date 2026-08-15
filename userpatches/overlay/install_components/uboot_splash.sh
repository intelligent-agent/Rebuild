#!/bin/bash

install_uboot_splash() {
    echo "🍰 install u-boot splash image"

    # Armbian only installs a boot logo when Plymouth is enabled, and even
    # then it just sets bootlogo=true in armbianEnv.txt - it never puts a
    # BMP on the boot partition. Install ours explicitly.
    #
    # The boot script (userpatches/bootscripts/boot-sun50i-next.cmd) loads
    # and displays this if it is present; setting splashfile= (empty) in
    # armbianEnv.txt turns it off.
    #
    # boot.bmp is a 480x480 24-bit uncompressed BMP, which is what U-Boot's
    # decoder accepts here (CONFIG_BMP_24BPP). U-Boot has no scaler, so the
    # image size is the displayed size.
    install -D -m 644 /tmp/overlay/splash/boot.bmp /boot/boot.bmp
}
