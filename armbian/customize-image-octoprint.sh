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
PREP_PACKAGE_LIST="avahi-daemon git iptables dnsmasq-base"

source /tmp/overlay/install_components/klipper.sh
source /tmp/overlay/install_components/octoprint.sh
source /tmp/overlay/install_components/toggle.sh
source /tmp/overlay/install_components/recore_binaries.sh
source /tmp/overlay/install_components/autohotspot.sh
source /tmp/overlay/install_components/ustreamer.sh
source /tmp/overlay/install_components/prep_install.sh
source /tmp/overlay/install_components/add_overlays.sh
source /tmp/overlay/install_components/fix_netplan.sh
source /tmp/overlay/install_components/post_build.sh

set -e

echo "🍰 Rebuild starting..."

prepare_build
install_klipper
install_octoprint
install_weston
install_toggle
install_ustreamer
install_bins
install_autohotspot
add_overlays
fix_netplan
post_build

echo "🍰 Rebuild finished"
