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
PREP_PACKAGE_LIST="git unzip"
ADD_PACKAGE_LIST="avahi-daemon"

source /tmp/overlay/install_components/klipper.sh
source /tmp/overlay/install_components/moonraker.sh
source /tmp/overlay/install_components/nginx.sh
source /tmp/overlay/install_components/fluidd.sh
source /tmp/overlay/install_components/klipperscreen.sh
source /tmp/overlay/install_components/recore_binaries.sh
source /tmp/overlay/install_components/ustreamer.sh
source /tmp/overlay/install_components/autohotspot.sh
source /tmp/overlay/install_components/auto_disable_ssh.sh
source /tmp/overlay/install_components/auto_switch_role.sh
source /tmp/overlay/install_components/rebuild_first_run.sh
source /tmp/overlay/install_components/prep_install.sh
source /tmp/overlay/install_components/add_overlays.sh
source /tmp/overlay/install_components/post_build.sh

echo "🍰 Rebuild starting..."

set -e

prepare_build
install_klipper "fluidd"
install_moonraker "fluidd"
install_nginx "fluidd"
install_fluidd
install_klipperscreen
install_ustreamer
install_bins
install_autohotspot
install_auto_disable_ssh
install_auto_switch_role
install_rebuild_first_run
add_overlays
post_build

systemctl disable getty@tty1.service

echo "🍰 Rebuild finished"
