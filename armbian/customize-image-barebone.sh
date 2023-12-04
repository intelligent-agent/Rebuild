#!/bin/bash

# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP
#
# This is the image customization script

# NOTE: It is copied to /tmp directory inside the image
# and executed there inside chroot environment
# so don't reference any files that are not already installed

# NOTE: If you want to transfer files between chroot and host
# userpatches/overlay directory on host is bind-mounted to /tmp/overlay in chroot
# The sd card's root path is accessible via $SDCARD variable.

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

install_bins(){
    cp /tmp/overlay/bins/* /usr/local/bin
    chmod +x /usr/local/bin/*
}

add_overlays(){
    mkdir /boot/overlay-user
    cp /tmp/overlay/dts/* /boot/overlay-user
}

fix_netplan(){
    cat <<- EOF > /etc/netplan/armbian-default.yaml
		network:
		  version: 2
		  renderer: NetworkManager
	EOF
}

prepare_build() {
    echo "ttyGS0" >> /etc/securetty
    systemctl enable serial-getty@ttyGS0.service
}

echo "🍰 Rebuild starting..."

prepare_build
install_bins
add_overlays
fix_netplan

cp /tmp/overlay/rebuild/rebuild-version /etc/

echo "🍰 Rebuild finished"
