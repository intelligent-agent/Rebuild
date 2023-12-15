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

PREP_PACKAGE_LIST="avahi-daemon iptables dnsmasq-base"

source /tmp/overlay/install_components/reflash.sh
source /tmp/overlay/install_components/add_overlays.sh
source /tmp/overlay/install_components/fix_netplan.sh

post_build() {
    echo "ttyGS0" >> /etc/securetty
    systemctl enable serial-getty@ttyGS0.service

    cp /tmp/overlay/rebuild/rebuild-version /etc/
}

echo "🍰 Rebuild starting..."

add_overlays
fix_netplan
install_reflash_board
post_build

echo "🍰 Rebuild finished"
