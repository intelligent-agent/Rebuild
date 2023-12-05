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
PREP_PACKAGE_LIST="avahi-daemon nginx git unzip iptables dnsmasq-base \
                    python3-virtualenv virtualenv python3-dev libffi-dev \
                    build-essential python3-cffi python3-libxml2 libncurses-dev\
                    libusb-dev stm32flash libnewlib-arm-none-eabi gcc-arm-none-eabi\
                    binutils-arm-none-eabi"

source "../install_components/klipper.sh"
source "../install_components/moonraker.sh"
source "../install_components/mainsail.sh"
source "../install_components/klipperscreen.sh"
source "../install_components/recore_binaries.sh"
source "../install_components/ustreamer.sh"
source "../install_components/autohotspot.sh"
source "../install_components/prep_install.sh"
source "../install_components/post_build.sh"
source "../install_components/add_overlays.sh"
source "../install_components/fix_netplan.sh"

set -e
echo "🍰 Rebuild starting..."
prepare_build
install_klipper
install_moonraker
install_mainsail
install_mainsail_nginx
install_klipperscreen
install_ustreamer
install_bins
install_autohotspot
add_overlays
fix_netplan
post_build

echo "🍰 Rebuild finished"
